#!/bin/bash

. ./cmd.sh ## You'll want to change cmd.sh to something that will work on your system.
           ## This relates to the queue.
. ./path.sh # so python3 is on the path if not on the system (we made a link to utils/).a

# This is a shell script, but it's recommended that you run the commands one by
# one by copying and pasting into the shell.

if [ $stage -le 0 ]; then
  # Download the corpus and prepare parallel lists of sound files and text files
  # Divide the corpus into train, dev and test sets
  local/sprak_data_prep.sh  || exit 1;
  utils/fix_data_dir.sh data/train || exit 1;

  # Perform text normalisation, prepare dict folder and LM data transcriptions
  local/copy_dict || exit 1;
fi

if [ $stage -le 1 ]; then
  utils/prepare_lang.sh data/local/dict "<UNK>" data/local/lang_tmp data/lang || exit 1;
fi

if [ $stage -le 2 ]; then
  # Extract mfccs 
  # p was added to the rspecifier (scp,p:$logdir/wav.JOB.scp) in make_mfcc.sh because some 
  # wave files are corrupt 
  # Will return a warning message because of the corrupt audio files, but compute them anyway
  # If this step fails and prints a partial diff, rerun from sprak_data_prep.sh
  steps/make_mfcc.sh --nj 10 --cmd "$train_cmd" data/test  || exit 1;
  steps/make_mfcc.sh --nj 10 --cmd "$train_cmd" data/train || exit 1;

  # Compute cepstral mean and variance normalisation
  steps/compute_cmvn_stats.sh data/test || exit 1; 
  steps/compute_cmvn_stats.sh data/train || exit 1;

  # Repair data set (remove corrupt data points with corrupt audio)
  utils/fix_data_dir.sh data/test || exit 1;
  utils/fix_data_dir.sh data/train || exit 1; 

  #speed test only 120 utterances per speaker
  utils/subset_data_dir.sh --per-spk data/test 120 data/test120_p_spk || exit 1; 
fi

if [ $stage -le 3 ]; then
  # Train LM with irstlm
  #creates 3g or fg dictionary and importantly G.fst
  local/train_irstlm.sh data/local/transcript_lm/transcripts.uniq 3 "tg" \
    data/lang data/local/train3_lm &> data/local/tg.log || exit 1; 
  local/train_irstlm.sh data/local/transcript_lm/transcripts.uniq 4 "fg" \
    data/lang data/local/train4_lm &> data/local/fg.log || exit 1; 
fi

if [ $stage -le 4 ]; then
  # Train monophone model on short utterances
  # AFTER THIS ONE CAN SEE THE ALIGNMNT BETWEEN FRAMES AND PHONES USING THE
  # COMMAND SHOW_ALIGNMENTS 
  steps/train_mono.sh --nj 10 --cmd "$train_cmd" \
    data/train data/lang exp/mono || exit 1;

  # Compose graphs
  utils/mkgraph.sh data/lang_test_tg exp/mono exp/mono/graph_tg || exit 1; 
  utils/mkgraph.sh data/lang_test_fg exp/mono exp/mono/graph_fg || exit 1; 
 
  # Ensure that all graphs are constructed
  steps/decode.sh --config conf/decode.config --nj 10 --cmd "$decode_cmd" \
    exp/mono/graph_fg data/test120_p_spk exp/mono/decode || exit 1;
fi

if [ $stage -le 5 ]; then
  # Get alignments from monophone system.
  steps/align_si.sh --nj 10 --cmd "$train_cmd" \
    data/train data/lang exp/mono exp/mono_ali || exit 1;
	 
  # train tri1 [first triphone pass]
  steps/train_deltas.sh --cmd "$train_cmd" \
    5800 96000 data/train data/lang exp/mono_ali exp/tri1 || exit 1;

  # make graph    
  utils/mkgraph.sh data/lang_test_fg exp/tri1 exp/tri1/graph_fg || exit 1;

  steps/decode.sh --config conf/decode.config --nj 10 --cmd "$decode_cmd" \
    exp/tri1/graph_fg data/test120_p_spk exp/tri1/decode_test120_p_spk || exit 1;
fi

if [ $stage -le 6 ]; then
  steps/align_si.sh --nj 10 --cmd "$train_cmd" \
    data/train data/lang exp/tri1 exp/tri1_ali || exit 1;

  # Train tri2a, which is deltas + delta-deltas.
  steps/train_deltas.sh --cmd "$train_cmd" \
    7500 125000 data/train data/lang exp/tri1_ali exp/tri2a || exit 1;

  utils/mkgraph.sh data/lang_test_fg exp/tri2a exp/tri2a/graph_fg || exit 1;

  steps/decode.sh --nj 10 --cmd "$decode_cmd" \
    exp/tri2a/graph_fg data/test120_p_spk exp/tri2a/decode_test120_p_spk|| exit 1;

  steps/train_lda_mllt.sh --cmd "$train_cmd" \
    --splice-opts "--left-context=5 --right-context=5" \
    7500 125000 data/train data/lang exp/tri1_ali exp/tri2b || exit 1;

  utils/mkgraph.sh data/lang_test_fg exp/tri2b exp/tri2b/graph_fg || exit 1;
  steps/decode.sh --nj 10 --cmd "$decode_cmd" \
    exp/tri2b/graph_fg data/test120_p_spk exp/tri2b/decode_test120_p_spk || exit 1;
fi


if [ $stage -le 7 ]; then
  steps/align_si.sh  --nj 10 --cmd "$train_cmd" \
    --use-graphs true data/train data/lang exp/tri2b exp/tri2b_ali  || exit 1;

  # From 2b system, train 3b which is LDA + MLLT + SAT.
  steps/train_sat.sh --cmd "$train_cmd" \
    7500 125000 data/train data/lang exp/tri2b_ali exp/tri3b || exit 1;

  # Trying 4-gram language model
  utils/mkgraph.sh data/lang_test_fg exp/tri3b exp/tri3b/graph_fg || exit 1;

  steps/decode_fmllr.sh --cmd "$decode_cmd" --nj 10 \
    exp/tri3b/graph_fg data/test120_p_spk exp/tri3b/decode_test120_p_spk || exit 1;
fi

if [ $stage -le 8 ]; then
  # From 3b system
  steps/align_fmllr.sh --nj 10 --cmd "$train_cmd" \
    data/train data/lang exp/tri3b exp/tri3b_ali || exit 1;

  # From 3b system, train another SAT system (tri4a) with all the si284 data.
  steps/train_sat.sh  --cmd "$train_cmd" \
    13000 300000 data/train data/lang exp/tri3b_ali exp/tri4a || exit 1;

  utils/mkgraph.sh data/lang_test_fg exp/tri4a exp/tri4a/graph_fg || exit 1;
  steps/decode_fmllr.sh --nj 10 --cmd "$decode_cmd" \
    exp/tri4a/graph_fg data/test120_p_spk exp/tri4a/decode_test120_p_spk || exit 1;
fi

if [ $stage -le 9 ]; then
# alignment used to train nnets
steps/align_fmllr.sh --nj 10 --cmd "$train_cmd" \
  data/train data/lang exp/tri4a exp/tri4a_ali || exit 1;
fi

## Works
local/sprak_run_nnet_cpu.sh fg test120_p_spk || exit 1; 

exit

# Run neural network setups based in the TEDLIUM recipe

# Running the nnet3-tdnn setup will train an ivector extractor that
# is used by the subsequent nnet3 and chain systems (why --stage is
# specified)
#local/nnet3/run_tdnn.sh --tdnn-affix "0" --nnet3-affix ""

# nnet3 LSTM
#local/nnet3/run_lstm.sh --stage 13 --affix "0"

# nnet3 bLSTM
#local/nnet3/run_blstm.sh --stage 12



# chain TDNN
# This setup creates a new lang directory that is also used by the
# TDNN-LSTM system
#local/chain/run_tdnn.sh --stage 14

# chain TDNN-LSTM
local/chain/run_tdnn_lstm.sh --stage 17


# Getting results [see RESULTS file]
#local/generate_results_file.sh 2> /dev/null > RESULTS


# Getting results [see RESULTS file]
#for x in exp/*/decode*; do [ -d $x ] && grep WER $x/wer_* | utils/best_wer.sh; done
