{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NegativeLiterals #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NondecreasingIndentation #-}
module FFMPEG where

import Foreign
import Foreign.C
import Data.Coerce (coerce)
import Control.Monad ((>=>), forM_, unless)
import Text.Read (readMaybe)
import Data.IORef (newIORef, writeIORef, readIORef)
import Control.Exception (bracket)

#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/imgutils.h"
#include "libavutil/opt.h"
#include "libswscale/swscale.h"
#include "libavfilter/avfilter.h"
#include "libavfilter/buffersink.h"
#include "libavfilter/buffersrc.h"

----------------------------

{#pointer *AVFormatContext as AVFormatContext newtype #}
deriving instance Storable AVFormatContext

{#pointer *AVFrame as AVFrame newtype #}
deriving instance Storable AVFrame
deriving instance Show AVFrame

{#pointer *AVPacket as AVPacket newtype #}
deriving instance Storable AVPacket
deriving instance Show AVPacket

{#pointer *AVCodec as AVCodec newtype #}
deriving instance Storable AVCodec
deriving instance Show AVCodec

{#pointer *AVCodecContext as AVCodecContext newtype #}
deriving instance Storable AVCodecContext
deriving instance Show AVCodecContext

{#pointer *AVStream as AVStream newtype #}
deriving instance Storable AVStream
deriving instance Show AVStream

{#pointer *AVFilter as AVFilter newtype #}
deriving instance Storable AVFilter
deriving instance Show AVFilter

{#pointer *AVFilterInOut as AVFilterInOut newtype #}
deriving instance Storable AVFilterInOut
deriving instance Show AVFilterInOut

{#pointer *AVFilterLink as AVFilterLink newtype #}
deriving instance Storable AVFilterLink
deriving instance Show AVFilterLink

{#pointer *AVFilterGraph as AVFilterGraph newtype #}
deriving instance Storable AVFilterGraph
deriving instance Show AVFilterGraph

{#pointer *AVFilterContext as AVFilterContext newtype #}
deriving instance Storable AVFilterContext
deriving instance Show AVFilterContext

{#pointer *AVDictionary as AVDictionary newtype #}
deriving instance Storable AVDictionary
deriving instance Show AVDictionary

{#pointer *AVDictionaryEntry as AVDictionaryEntry newtype #}
deriving instance Storable AVDictionaryEntry
deriving instance Show AVDictionaryEntry

{#enum AVCodecID {} deriving (Eq, Show) #}

{#enum AVMediaType {} deriving (Eq, Show) #}

{#enum AVPixelFormat {} deriving (Eq, Show) #}

{#enum AVSampleFormat {} deriving (Eq, Show) #}

{#enum AV_BUFFERSRC_FLAG_NO_CHECK_FORMAT as AV_BUFFERSRC_FLAG {}
  deriving (Eq, Show) #}

{#pointer *AVCodecParameters as AVCodecParameters newtype #}
deriving instance Storable AVCodecParameters

{#pointer *SwsContext as SwsContext newtype #}
deriving instance Show SwsContext

-----------------------------

{#fun avformat_alloc_context
  {} -> `AVFormatContext'
#}

{#fun avformat_free_context
  { `AVFormatContext'
  } -> `()'
#}

{#fun avformat_open_input
  { id `Ptr AVFormatContext'
  , `CString'
  , id `Ptr ()'
  , id `Ptr AVDictionary'
  } -> `CInt'
#}

{#fun avformat_close_input
  { id `Ptr AVFormatContext'
  } -> `()'
#}

{#fun av_dump_format
  { `AVFormatContext'
  , `CInt'
  , `CString'
  , `CInt'
  } -> `()'
#}

{#fun avformat_find_stream_info
  { `AVFormatContext'
  , id `Ptr AVDictionary'
  } -> `CInt'
#}

{#fun av_frame_alloc
  {} -> `AVFrame'
#}

{#fun av_frame_free
  { id `Ptr AVFrame'
  } -> `()'
#}

{#fun av_frame_unref
  { `AVFrame'
  } -> `()'
#}

{#fun av_packet_alloc
  {} -> `AVPacket'
#}

{#fun av_packet_free
  { id `Ptr AVPacket'
  } -> `()'
#}

{#fun av_packet_unref
  { `AVPacket'
  } -> `()'
#}

{#fun av_read_frame
  { `AVFormatContext'
  , `AVPacket'
  } -> `CInt'
#}

{#fun av_seek_frame
  { `AVFormatContext'
  , `CInt'
  , `Int64'
  , `CInt'
  } -> `CInt'
#}

getStreams :: AVFormatContext -> IO [AVStream]
getStreams ctx = do
  n <- {#get AVFormatContext->nb_streams#} ctx
  p <- {#get AVFormatContext->streams#} ctx
  peekArray (fromIntegral n) p

stream_index :: AVStream -> IO CInt
stream_index = {#get AVStream->index #}

stream_codecpar :: AVStream -> IO AVCodecParameters
stream_codecpar = {#get AVStream->codecpar #}

avfc_duration :: AVFormatContext -> IO Double
avfc_duration fc = do
  n <- {#get AVFormatContext->duration #} fc
  return $ realToFrac n / {#const AV_TIME_BASE #}

codec_type :: AVCodecParameters -> IO AVMediaType
codec_type = fmap (toEnum . fromIntegral) . {#get AVCodecParameters->codec_type #}

codec_id :: AVCodecParameters -> IO AVCodecID
codec_id = fmap (toEnum . fromIntegral) . {#get AVCodecParameters->codec_id #}

cp_width, cp_height :: AVCodecParameters -> IO CInt
cp_width  = {#get AVCodecParameters->width  #}
cp_height = {#get AVCodecParameters->height #}

-- only an AVPixelFormat for video streams; for audio, it's a AVSampleFormat
-- cp_format :: AVCodecParameters -> IO AVPixelFormat
-- cp_format = fmap (toEnum . fromIntegral) . {#get AVCodecParameters->format #}

{#fun avcodec_find_decoder
  { `AVCodecID'
  } -> `AVCodec'
#}

{#fun avcodec_find_encoder
  { `AVCodecID'
  } -> `AVCodec'
#}

time_base :: AVStream -> IO (CInt, CInt)
time_base s = do
  num <- {#get AVStream->time_base.num #} s
  den <- {#get AVStream->time_base.den #} s
  return (num, den)

{#fun avcodec_alloc_context3
  { `AVCodec'
  } -> `AVCodecContext'
#}

{#fun avcodec_free_context
  { id `Ptr AVCodecContext'
  } -> `()'
#}

{#fun avcodec_parameters_to_context
  { `AVCodecContext'
  , `AVCodecParameters'
  } -> `CInt'
#}

{#fun avcodec_open2
  { `AVCodecContext'
  , `AVCodec'
  , id `Ptr AVDictionary'
  } -> `CInt'
#}

packet_stream_index :: AVPacket -> IO CInt
packet_stream_index = {#get AVPacket->stream_index #}

{#fun avcodec_send_packet
  { `AVCodecContext'
  , `AVPacket'
  } -> `CInt'
#}

{#fun avcodec_receive_frame
  { `AVCodecContext'
  , `AVFrame'
  } -> `CInt'
#}

{#fun avcodec_send_frame
  { `AVCodecContext'
  , `AVFrame'
  } -> `CInt'
#}

{#fun avcodec_receive_packet
  { `AVCodecContext'
  , `AVPacket'
  } -> `CInt'
#}

{#fun sws_getContext
  { `CInt'
  , `CInt'
  , `AVPixelFormat'
  , `CInt'
  , `CInt'
  , `AVPixelFormat'
  , `CInt'
  , `Ptr ()'
  , `Ptr ()'
  , id `Ptr CDouble'
  } -> `SwsContext'
#}

{#fun sws_scale
  { `SwsContext'
  , id `Ptr (Ptr CUChar)'
  , id `Ptr CInt'
  , `CInt'
  , `CInt'
  , id `Ptr (Ptr CUChar)'
  , id `Ptr CInt'
  } -> `CInt'
#}

sws_BILINEAR :: CInt
sws_BILINEAR = {#const SWS_BILINEAR #}

pix_fmt :: AVCodecContext -> IO AVPixelFormat
pix_fmt = fmap (toEnum . fromIntegral) . {#get AVCodecContext->pix_fmt #}

{#fun av_image_fill_arrays
  { id `Ptr (Ptr CUChar)'
  , id `Ptr CInt'
  , id `Ptr CUChar'
  , `AVPixelFormat'
  , `CInt'
  , `CInt'
  , `CInt'
  } -> `CInt'
#}

frame_data :: AVFrame -> IO (Ptr (Ptr CUChar))
frame_data = {#get AVFrame->data #}

frame_linesize :: AVFrame -> IO (Ptr CInt)
frame_linesize = {#get AVFrame->linesize #}

frame_pts :: AVFrame -> IO Int64
frame_pts = fmap fromIntegral . {#get AVFrame->pts #}

ctx_set_pix_fmt :: AVCodecContext -> AVPixelFormat -> IO ()
ctx_set_pix_fmt c = {#set AVCodecContext->pix_fmt #} c . fromIntegral . fromEnum

ctx_set_height :: AVCodecContext -> CInt -> IO ()
ctx_set_height = {#set AVCodecContext->height #}

ctx_set_width :: AVCodecContext -> CInt -> IO ()
ctx_set_width = {#set AVCodecContext->width #}

ctx_set_codec_type :: AVCodecContext -> AVMediaType -> IO ()
ctx_set_codec_type c = {#set AVCodecContext->codec_type #} c . fromIntegral . fromEnum

ctx_set_time_base_num :: AVCodecContext -> CInt -> IO ()
ctx_set_time_base_num = {#set AVCodecContext->time_base.num #}

ctx_set_time_base_den :: AVCodecContext -> CInt -> IO ()
ctx_set_time_base_den = {#set AVCodecContext->time_base.den #}

{#fun av_init_packet
  { `AVPacket'
  } -> `()'
#}

packet_set_size :: AVPacket -> CInt -> IO ()
packet_set_size = {#set AVPacket->size #}

packet_set_data :: AVPacket -> Ptr CUChar -> IO ()
packet_set_data = {#set AVPacket->data #}

{#fun av_image_alloc
  { id `Ptr (Ptr CUChar)'
  , id `Ptr CInt'
  , `CInt'
  , `CInt'
  , `AVPixelFormat'
  , `CInt'
  } -> `CInt'
#}

{#fun av_freep
  { castPtr `Ptr a'
  } -> `()'
#}

{#fun av_free
  { castPtr `Ptr a'
  } -> `()'
#}

frame_set_width :: AVFrame -> CInt -> IO ()
frame_set_width = {#set AVFrame->width #}

frame_set_height :: AVFrame -> CInt -> IO ()
frame_set_height = {#set AVFrame->height #}

frame_set_format :: AVFrame -> AVPixelFormat -> IO ()
frame_set_format f = {#set AVFrame->format #} f . fromIntegral . fromEnum

packet_size :: AVPacket -> IO CInt
packet_size = {#get AVPacket->size #}

packet_data :: AVPacket -> IO (Ptr CUChar)
packet_data = {#get AVPacket->data #}

-- deprecated
{#fun avcodec_decode_video2
  { `AVCodecContext'
  , `AVFrame'
  , id `Ptr CInt'
  , `AVPacket'
  } -> `CInt'
#}

{#fun av_log_set_level
  { `CInt'
  } -> `()'
#}

avseek_FLAG_BACKWARD :: CInt
avseek_FLAG_BACKWARD = {#const AVSEEK_FLAG_BACKWARD #}

{#fun av_find_best_stream
  { `AVFormatContext'
  , `AVMediaType'
  , `CInt'
  , `CInt'
  , id `Ptr AVCodec'
  , `CInt'
  } -> `CInt'
#}

{#fun avfilter_get_by_name
  { `CString'
  } -> `AVFilter'
#}

{#fun avfilter_inout_alloc
  {} -> `AVFilterInOut'
#}

{#fun avfilter_inout_free
  { id `Ptr AVFilterInOut'
  } -> `()'
#}

{#fun avfilter_graph_alloc
  {} -> `AVFilterGraph'
#}

{#fun avfilter_graph_free
  { id `Ptr AVFilterGraph'
  } -> `()'
#}

{#fun avfilter_graph_create_filter
  { id `Ptr AVFilterContext'
  , `AVFilter'
  , `CString'
  , `CString'
  , `Ptr ()'
  , `AVFilterGraph'
  } -> `CInt'
#}

{#fun av_buffersrc_add_frame_flags
  { `AVFilterContext'
  , `AVFrame'
  , `CInt'
  } -> `CInt'
#}

{#fun av_buffersink_get_frame
  { `AVFilterContext'
  , `AVFrame'
  } -> `CInt'
#}

{#fun av_get_default_channel_layout
  { `CInt'
  } -> `Int64'
#}

{#fun av_get_sample_fmt_name
  { `AVSampleFormat'
  } -> `CString'
#}

{#fun av_opt_set_bin
  { castPtr `Ptr obj'
  , `CString'
  , castPtr `Ptr Word8'
  , `CInt'
  , `CInt'
  } -> `CInt'
#}

{#fun av_strdup
  { `CString'
  } -> `CString'
#}

av_OPT_SEARCH_CHILDREN :: CInt
av_OPT_SEARCH_CHILDREN = 1 -- AV_OPT_SEARCH_CHILDREN is "1 << 0"

av_opt_set_int_list :: (Storable a) => Ptr obj -> String -> [a] -> CInt -> IO CInt
av_opt_set_int_list obj name vals flags = do
  let arraySize = fromIntegral $ sizeOf (head vals) * length vals -- TODO this is not necessarily right, see av_int_list_length
  withArray vals $ \pvals -> do
    withCString name $ \pname -> do
      av_opt_set_bin obj pname (castPtr pvals) arraySize flags

{#fun avfilter_graph_parse_ptr
  { `AVFilterGraph'
  , `CString'
  , id `Ptr AVFilterInOut'
  , id `Ptr AVFilterInOut'
  , `Ptr ()'
  } -> `CInt'
#}

{#fun avfilter_graph_config
  { `AVFilterGraph'
  , `Ptr ()'
  } -> `CInt'
#}

{#fun av_dict_get
  { `AVDictionary'
  , `CString'
  , `AVDictionaryEntry'
  , `CInt'
  } -> `AVDictionaryEntry'
#}

{#fun av_dict_count
  { `AVDictionary'
  } -> `CInt'
#}

{#fun av_dict_get_string
  { `AVDictionary'
  , id `Ptr CString'
  , id `CChar'
  , id `CChar'
  } -> `CInt'
#}

{#fun av_get_channel_layout_nb_channels
  { `Word64'
  } -> `CInt'
#}

-- TODO clean up, better resource allocation, get rid of unnecessary audio format conversion from sample code
audioIntegratedVolume :: FilePath -> IO (Maybe Float)
audioIntegratedVolume f = do

  let check s test act = act >>= \ret -> unless (test ret) $ error $ s <> " returned " <> show ret

  bracket avformat_alloc_context (\p -> with p avformat_close_input) $ \fmt_ctx -> do
  with fmt_ctx $ \pctx -> do
    withCString f $ \s -> do
      check "avformat_open_input" (== 0) $ avformat_open_input pctx s nullPtr nullPtr
  check "avformat_find_stream_info" (>= 0) $ avformat_find_stream_info fmt_ctx nullPtr
  (audio_stream_index, dec) <- alloca $ \pdec -> do
    audio_stream_index <- av_find_best_stream fmt_ctx AVMEDIA_TYPE_AUDIO -1 -1 pdec 0
    dec <- peek pdec
    return (audio_stream_index, dec)
  bracket (avcodec_alloc_context3 dec) (\p -> with p avcodec_free_context) $ \dec_ctx -> do
  stream <- (!! fromIntegral (audio_stream_index)) <$> getStreams fmt_ctx
  params <- stream_codecpar stream
  check "avcodec_parameters_to_context" (>= 0) $ avcodec_parameters_to_context dec_ctx params
  check "avcodec_open2" (== 0) $ avcodec_open2 dec_ctx dec nullPtr

  let filters_descr = "ebur128=metadata=1,aresample=8000,aformat=sample_fmts=s16:channel_layouts=mono"
  abuffersrc <- withCString "abuffer" avfilter_get_by_name
  abuffersink <- withCString "abuffersink" avfilter_get_by_name
  outputs <- avfilter_inout_alloc
  inputs <- avfilter_inout_alloc
  -- print (abuffersrc, abuffersink, outputs, inputs)
  let out_sample_fmts = [fromIntegral $ fromEnum AV_SAMPLE_FMT_S16] :: [CInt]
      out_channel_layouts = [{#const AV_CH_LAYOUT_MONO #}] :: [Int64]
      out_sample_rates = [8000] :: [CInt]
  (num, den) <- time_base stream

  bracket avfilter_graph_alloc (\p -> with p avfilter_graph_free) $ \filter_graph -> do
  -- print filter_graph

  -- buffer audio source: the decoded frames from the decoder will be inserted here.
  {#get AVCodecContext->channel_layout #} dec_ctx >>= \case
    0 -> {#get AVCodecContext->channels #} dec_ctx
      >>= av_get_default_channel_layout
      >>= {#set AVCodecContext->channel_layout #} dec_ctx . fromIntegral
    _ -> return ()
  args <- do
    rate <- {#get AVCodecContext->sample_rate #} dec_ctx
    fmt <- {#get AVCodecContext->sample_fmt #} dec_ctx >>= av_get_sample_fmt_name . toEnum . fromIntegral >>= peekCString
    layout <- {#get AVCodecContext->channel_layout #} dec_ctx
    return $ concat ["time_base=", show num, "/", show den, ":sample_rate=", show rate, ":sample_fmt=", fmt, ":channel_layout=", show layout]
  -- print args
  buffersrc_ctx <- alloca $ \p -> do
    withCString "in" $ \pname -> do
      withCString args $ \pargs -> do
        check "avfilter_graph_create_filter" (>= 0) $ do
          avfilter_graph_create_filter p abuffersrc pname pargs nullPtr filter_graph
    peek p
  -- print buffersrc_ctx

  -- buffer audio sink: to terminate the filter chain.
  buffersink_ctx <- alloca $ \p -> do
    withCString "out" $ \pname -> do
      check "avfilter_graph_create_filter" (>= 0) $ do
        avfilter_graph_create_filter p abuffersink pname nullPtr nullPtr filter_graph
    peek p

  check "av_opt_set_int_list (sample_fmts)" (>= 0) $ do
    av_opt_set_int_list (coerce buffersink_ctx) "sample_fmts"     out_sample_fmts     av_OPT_SEARCH_CHILDREN
  check "av_opt_set_int_list (channel_layouts)" (>= 0) $ do
    av_opt_set_int_list (coerce buffersink_ctx) "channel_layouts" out_channel_layouts av_OPT_SEARCH_CHILDREN
  check "av_opt_set_int_list (sample_rates)" (>= 0) $ do
    av_opt_set_int_list (coerce buffersink_ctx) "sample_rates"    out_sample_rates    av_OPT_SEARCH_CHILDREN

  -- Set the endpoints for the filter graph. The filter_graph will
  -- be linked to the graph described by filters_descr.

  -- The buffer source output must be connected to the input pad of
  -- the first filter described by filters_descr; since the first
  -- filter input label is not specified, it is set to "in" by
  -- default.
  withCString "in" $ av_strdup >=> {#set AVFilterInOut->name #} outputs
  {#set AVFilterInOut->filter_ctx #} outputs buffersrc_ctx
  {#set AVFilterInOut->pad_idx #} outputs 0
  {#set AVFilterInOut->next #} outputs $ AVFilterInOut nullPtr

  -- The buffer sink input must be connected to the output pad of
  -- the last filter described by filters_descr; since the last
  -- filter output label is not specified, it is set to "out" by
  -- default.
  withCString "out" $ av_strdup >=> {#set AVFilterInOut->name #} inputs
  {#set AVFilterInOut->filter_ctx #} inputs buffersink_ctx
  {#set AVFilterInOut->pad_idx #} inputs 0
  {#set AVFilterInOut->next #} inputs $ AVFilterInOut nullPtr

  (inputs', outputs') <- withCString filters_descr $ \cstr -> do
    with inputs $ \pinputs -> do
      with outputs $ \poutputs -> do
        check "avfilter_graph_parse_ptr" (>= 0) $ do
          avfilter_graph_parse_ptr filter_graph cstr pinputs poutputs nullPtr
        (,) <$> peek pinputs <*> peek poutputs

  check "avfilter_graph_config" (>= 0) $ avfilter_graph_config filter_graph nullPtr

  -- Print summary of the sink buffer
  -- Note: args buffer is reused to store channel layout string

  -- outlink = buffersink_ctx->inputs[0];
  -- av_get_channel_layout_string(args, sizeof(args), -1, outlink->channel_layout);
  -- av_log(NULL, AV_LOG_INFO, "Output: srate:%dHz fmt:%s chlayout:%s\n",
  --        (int)outlink->sample_rate,
  --        (char *)av_x_if_null(av_get_sample_fmt_name(outlink->format), "?"),
  --        args);

  with inputs' avfilter_inout_free
  with outputs' avfilter_inout_free

  -- read all packets
  bracket av_frame_alloc (\p -> with p av_frame_free) $ \frame -> do
  bracket av_frame_alloc (\p -> with p av_frame_free) $ \filt_frame -> do
  vol <- newIORef Nothing
  alloca $ \(AVPacket -> packet) -> let
    readFrame = do
      ret <- av_read_frame fmt_ctx packet
      if ret < 0
        then return () -- out of frames
        else do
          si <- packet_stream_index packet
          if si == audio_stream_index
            then do
              -- this is an audio packet
              avcodec_send_packet dec_ctx packet >>= \case
                0 -> return ()
                n -> putStrLn $ "avcodec_send_packet: " <> show n
              av_packet_unref packet
              receiveFrame
              readFrame
            else do
              av_packet_unref packet
              readFrame
    receiveFrame = do
      ret <- avcodec_receive_frame dec_ctx frame
      if ret < 0
        then return () -- need more packets
        else do
          -- push the audio data from decoded frame into the filtergraph
          av_buffersrc_add_frame_flags buffersrc_ctx frame (fromIntegral $ fromEnum AV_BUFFERSRC_FLAG_KEEP_REF) >>= \case
            0 -> return ()
            n -> putStrLn $ "av_buffersrc_add_frame_flags: " <> show n
          -- pull filtered audio from the filtergraph
          pullAudio
          av_frame_unref frame
    pullAudio = do
      ret <- av_buffersink_get_frame buffersink_ctx filt_frame
      if ret < 0
        then return () -- no data available, graph needs more input
        else do

          -- nsamples <- {#get AVFrame->nb_samples #} filt_frame
          -- nchannels <- {#get AVFrame->channel_layout #} filt_frame >>= av_get_channel_layout_nb_channels . fromIntegral
          -- let nbytes = nsamples * nchannels * 2
          -- p <- frame_data filt_frame >>= peek
          -- B.packCStringLen (castPtr p, fromIntegral nbytes) >>= B.hPut h

          meta <- {#get AVFrame->metadata #} filt_frame
          entry <- withCString "lavfi.r128.I" $ \k -> av_dict_get meta k (AVDictionaryEntry nullPtr) 0
          case entry of
            AVDictionaryEntry p | p == nullPtr -> return ()
            _ -> do
              s <- {#get AVDictionaryEntry->value #} entry >>= peekCString
              forM_ (readMaybe s) $ writeIORef vol . Just
          av_frame_unref filt_frame
          pullAudio
    in readFrame

  readIORef vol
