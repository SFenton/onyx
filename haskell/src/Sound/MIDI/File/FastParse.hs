{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms   #-}
module Sound.MIDI.File.FastParse (getMIDI) where

import           Control.Applicative                   (liftA2)
import           Data.Binary.Get
import           Data.Bits                             (shiftR, testBit, (.&.))
import qualified Data.ByteString                       as B
import qualified Data.ByteString.Char8                 as B8
import qualified Data.ByteString.Lazy                  as BL
import qualified Data.EventList.Relative.TimeBody      as RTB
import           Data.Word                             (Word32, Word8)
import qualified Numeric.NonNegative.Wrapper           as NN
import           RockBand.Common                       (pattern RNil,
                                                        pattern Wait)
import qualified Sound.MIDI.File                       as F
import qualified Sound.MIDI.File.Event                 as E
import qualified Sound.MIDI.File.Event.Meta            as Meta
import qualified Sound.MIDI.File.Event.SystemExclusive as SysEx
import qualified Sound.MIDI.KeySignature               as Key
import qualified Sound.MIDI.Message.Channel            as C
import qualified Sound.MIDI.Message.Channel.Mode       as Mode
import qualified Sound.MIDI.Message.Channel.Voice      as V

getMIDI :: Get F.T
getMIDI = do
  chunks <- getChunks
  case chunks of
    ("MThd", header) : rest -> do
      let (fmt, ntrks, dvn) = runGet getHeader header
          tracks = map (runGet getTrack . snd) $ filter ((== "MTrk") . fst) rest
      return $ F.Cons fmt dvn $ take ntrks tracks
    _ -> fail "Couldn't find MIDI header chunk at start"

getChunks :: Get [(B.ByteString, BL.ByteString)]
getChunks = isEmpty >>= \case
  True -> return []
  False -> let
    getChunk = do
      magic <- getByteString 4
      size <- getWord32be
      chunk <- getLazyByteString $ fromIntegral size
      return (magic, chunk)
    -- TODO handle various errors gracefully
    in liftA2 (:) getChunk getChunks

getHeader :: Get (F.Type, Int, F.Division)
getHeader = do
  fmt <- getWord16be >>= \case
    0 -> return F.Mixed
    1 -> return F.Parallel
    2 -> return F.Serial
    n -> fail $ "Unknown MIDI file type: " <> show n
  ntrks <- fromIntegral <$> getWord16be
  dvn <- getInt16be
  let dvn' = if dvn >= 0
        then F.Ticks $ fromIntegral dvn
        else F.SMPTE
          (negate $ fromIntegral $ dvn `shiftR` 8)
          (fromIntegral $ dvn .&. 0xFF)
  return (fmt, ntrks, dvn')

getVariableNum :: Get Int
getVariableNum = readVariableBytes <$> getVariableBytes where
  getVariableBytes = do
    b <- getWord8
    if b > 0x7F
      then ((b .&. 0x7F) :) <$> getVariableBytes
      else return [b]
  bytePlaces = 1 : map (* 0x80) bytePlaces
  readVariableBytes = sum . zipWith (*) bytePlaces . reverse . map fromIntegral

getWord24be :: Get Word32
getWord24be = do
  x <- getWord8
  y <- getWord16be
  return $ fromIntegral x * 0x10000 + fromIntegral y

getTrack :: Get (RTB.T NN.Integer E.T)
getTrack = removeEnd <$> go Nothing where
  removeEnd (Wait _ (E.MetaEvent Meta.EndOfTrack) RNil) = RNil
  removeEnd (Wait dt x rest) = Wait dt x $ removeEnd rest
  removeEnd RNil = RNil
  go running = isEmpty >>= \case
    True -> return RTB.empty
    False -> do
      tks <- getVariableNum
      (e, running') <- getWord8 >>= \case
        0xFF -> do
          metaType <- getWord8
          metaLen <- getVariableNum
          let str = B8.unpack <$> getByteString metaLen
          e <- E.MetaEvent <$> case (metaType, metaLen) of
            (0x00, 2) -> Meta.SequenceNum . fromIntegral <$> getWord16be
            (0x01, _) -> Meta.TextEvent <$> str
            (0x02, _) -> Meta.Copyright <$> str
            (0x03, _) -> Meta.TrackName <$> str
            (0x04, _) -> Meta.InstrumentName <$> str
            (0x05, _) -> Meta.Lyric <$> str
            (0x06, _) -> Meta.Marker <$> str
            (0x07, _) -> Meta.CuePoint <$> str
            (0x20, 1) -> Meta.MIDIPrefix . C.toChannel . fromIntegral <$> getWord8
            (0x2F, 0) -> return Meta.EndOfTrack
            (0x51, 3) -> Meta.SetTempo . fromIntegral <$> getWord24be
            (0x54, 5) -> do
              [hr, mn, se, fr, ff] <- map fromIntegral . B.unpack <$> getByteString 5
              return $ Meta.SMPTEOffset hr mn se fr ff
            (0x58, 4) -> do
              [nn, dd, cc, bb] <- map fromIntegral . B.unpack <$> getByteString 4
              return $ Meta.TimeSig nn dd cc bb
            (0x59, 2) -> do
              sf <- getWord8
              mi <- getWord8
              return $ Meta.KeySig $ Key.Cons
                (case mi of 0 -> Key.Major; _ -> Key.Minor) -- technically only 1 should be minor
                (Key.Accidentals $ fromIntegral sf)
            (0x7F, _) -> Meta.SequencerSpecific . B.unpack <$> getByteString metaLen
            _ -> Meta.Unknown (fromIntegral metaType) . B.unpack <$> getByteString metaLen
          return (e, running) -- to be correct, this should clear running status
        0xF0 -> do
          sysexLen <- getVariableNum
          e <- E.SystemExclusive . SysEx.Regular . B.unpack <$> getByteString sysexLen
          return (e, running) -- to be correct, this should clear running status
        0xF7 -> do
          sysexLen <- getVariableNum
          e <- E.SystemExclusive . SysEx.Escape . B.unpack <$> getByteString sysexLen
          return (e, running) -- to be correct, this should clear running status
        n -> do
          (statusByte, getFirstByte) <- if n `testBit` 7
            then return (n, getWord8)
            else case running of
              Just runningByte -> return (runningByte, return n)
              Nothing -> fail "Event needs running status but none is set"
          let chan = C.Cons $ C.toChannel $ fromIntegral $ statusByte .&. 0xF
              int7Bits b = fromIntegral $ (b :: Word8) .&. 0x7F :: Int
          e <- E.MIDIEvent . chan <$> case statusByte `shiftR` 4 of
            0x8 -> (\k v -> C.Voice $ V.NoteOff k v)
              <$> (V.toPitch . int7Bits <$> getFirstByte)
              <*> (V.toVelocity . int7Bits <$> getWord8)
            0x9 -> (\k v -> C.Voice $ V.NoteOn k v)
              <$> (V.toPitch . int7Bits <$> getFirstByte)
              <*> (V.toVelocity . int7Bits <$> getWord8)
            0xA -> (\k v -> C.Voice $ V.PolyAftertouch k v)
              <$> (V.toPitch . int7Bits <$> getFirstByte)
              <*> (int7Bits <$> getWord8)
            0xB -> do
              c <- int7Bits <$> getFirstByte
              v <- int7Bits <$> getWord8
              case (c, v) of
                (120, 0) -> return $ C.Mode Mode.AllSoundOff
                (121, 0) -> return $ C.Mode Mode.ResetAllControllers
                (122, 0) -> return $ C.Mode $ Mode.LocalControl False
                (122, 127) -> return $ C.Mode $ Mode.LocalControl True
                (123, 0) -> return $ C.Mode Mode.AllNotesOff
                (124, 0) -> return $ C.Mode $ Mode.OmniMode False
                (125, 0) -> return $ C.Mode $ Mode.OmniMode True
                (126, _) -> return $ C.Mode $ Mode.MonoMode v
                (127, 0) -> return $ C.Mode Mode.PolyMode
                _ -> return $ C.Voice $ V.Control (V.toController c) v
            0xC -> C.Voice . V.ProgramChange
              <$> (V.toProgram . int7Bits <$> getFirstByte)
            0xD -> C.Voice . V.MonoAftertouch
              <$> (int7Bits <$> getFirstByte)
            0xE -> do
              x <- getFirstByte
              y <- getWord8
              return $ C.Voice $ V.PitchBend $
                int7Bits x * 0x80 + int7Bits y
            -- 0xF is meta/sysex, handled above
            _ -> fail $ "Unknown event byte: " <> show statusByte
          return (e, Just statusByte)
      RTB.cons (fromIntegral tks) e <$> go running'