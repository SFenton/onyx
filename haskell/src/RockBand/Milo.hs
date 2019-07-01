{-
Thanks to PyMilo, LibForge, and MiloMod for information on these structures.
-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms   #-}
{-# LANGUAGE RecordWildCards   #-}
module RockBand.Milo where

import qualified Codec.Compression.GZip           as GZ
import qualified Codec.Compression.Zlib.Internal  as Z
import           Control.Monad                    (forM, forM_, replicateM)
import           Control.Monad.ST.Lazy
import           Control.Monad.Trans.StackTrace   (logStdout, stackIO)
import           Data.Binary.Get
import           Data.Binary.IEEE754              (getFloat32be)
import           Data.Binary.Put
import           Data.Bits
import qualified Data.ByteString                  as B
import qualified Data.ByteString.Char8            as B8
import qualified Data.ByteString.Lazy             as BL
import qualified Data.EventList.Absolute.TimeBody as ATB
import qualified Data.EventList.Relative.TimeBody as RTB
import           Data.List                        (foldl')
import           Data.List.Split                  (keepDelimsR, onSublist,
                                                   split)
import           Data.Word
import           DryVox                           (vocalTubes)
import qualified Numeric.NonNegative.Wrapper      as NN
import qualified RockBand.Codec.File              as RBFile
import           RockBand.Codec.Lipsync           (LipsyncTrack (..),
                                                   MagmaViseme (..), Slide (..))
import           RockBand.Codec.Vocal
import           RockBand.Common                  (pattern RNil, pattern Wait)
import qualified Sound.MIDI.File.Event            as E
import qualified Sound.MIDI.File.Event.Meta       as Meta
import qualified Sound.MIDI.File.Load             as Load
import qualified Sound.MIDI.File.Save             as Save
import qualified Sound.MIDI.Util                  as U

data MiloCompression
  = MILO_A
  | MILO_B
  | MILO_C
  | MILO_D
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

-- decompresses zlib stream, but ignores "input ended prematurely" error
zlibTruncate :: BL.ByteString -> BL.ByteString
zlibTruncate bs = runST $ let
  go input = \case
    Z.DecompressInputRequired f              -> case input of
      []     -> f B.empty >>= go []
      x : xs -> f x       >>= go xs
    Z.DecompressOutputAvailable out getNext  -> do
      next <- getNext
      (BL.fromStrict out <>) <$> go input next
    Z.DecompressStreamEnd _unread            -> return BL.empty
    Z.DecompressStreamError Z.TruncatedInput -> return BL.empty
    Z.DecompressStreamError err              ->
      error $ "Milo Zlib decompression error: " <> show err
  in go (BL.toChunks bs) $ Z.decompressST Z.zlibFormat Z.defaultDecompressParams

decompressBlock :: MiloCompression -> BL.ByteString -> BL.ByteString
decompressBlock comp bs = case comp of
  MILO_A -> bs
  MILO_B -> zlibTruncate $ zlib_info <> bs
  MILO_C -> GZ.decompress bs
  MILO_D -> zlibTruncate $ zlib_info <> BL.drop 4 (BL.take (BL.length bs - 1) bs)
  where zlib_info = BL.pack [0x78, 0x9C]

decompressMilo :: Get BL.ByteString
decompressMilo = do
  startingOffset <- bytesRead
  comp <- getWord32le >>= \case
    0xCABEDEAF -> return MILO_A
    0xCBBEDEAF -> return MILO_B
    0xCCBEDEAF -> return MILO_C
    0xCDBEDEAF -> return MILO_D
    n          -> fail $ "Unrecognized .milo compression: " <> show n
  offset <- getWord32le
  blockCount <- getWord32le
  _largestBlock <- getWord32le -- max uncompressed size
  let maxSize = 1 `shiftL` 24
  blockInfo <- replicateM (fromIntegral blockCount) $ do
    size <- getWord32le
    let (compressed, size') = case comp of
          MILO_A -> (False, size)
          MILO_D ->
            ( size .&. maxSize == 0
            , size .&. complement maxSize
            )
          _      -> (True, size)
    return (size', compressed)
  posn <- bytesRead
  skip $ fromIntegral offset - fromIntegral (posn - startingOffset)
  fmap BL.concat $ forM blockInfo $ \(size, compressed) -> do
    bs <- getLazyByteString $ fromIntegral size
    return $ if compressed then decompressBlock comp bs else bs

addMiloHeader :: BL.ByteString -> BL.ByteString
addMiloHeader bs = let
  barrier = [0xAD, 0xDE, 0xAD, 0xDE]
  headerSize = 0x810
  chunks = map (fromIntegral . length) $ filter (not . null) $
    case split (keepDelimsR $ onSublist barrier) $ BL.unpack bs of
      []           -> []
      [c]          -> [c]
      c1 : c2 : cs -> (c1 ++ c2) : cs
  header = runPut $ do
    putWord32le 0xCABEDEAF
    putWord32le headerSize
    putWord32le $ fromIntegral $ length chunks
    putWord32le $ foldl' max 0 chunks
    mapM_ putWord32le chunks
  in BL.concat
    [ header
    , BL.replicate (fromIntegral headerSize - BL.length header) 0
    , bs
    ]

data MagmaLipsync
  = MagmaLipsync1 Lipsync
  | MagmaLipsync2 Lipsync Lipsync
  | MagmaLipsync3 Lipsync Lipsync Lipsync
  deriving (Eq, Show)

magmaMilo :: MagmaLipsync -> BL.ByteString
magmaMilo ml = addMiloHeader $ runPut $ do
  putWord32be 0x1C
  putStringBE "ObjectDir"
  putStringBE "lipsync"
  case ml of
    MagmaLipsync1{} -> do
      putWord32be 4
      putWord32be 0x15
      putWord32be 1
    MagmaLipsync2{} -> do
      putWord32be 6
      putWord32be 0x23
      putWord32be 2
    MagmaLipsync3{} -> do
      putWord32be 8
      putWord32be 0x31
      putWord32be 3
  case ml of
    MagmaLipsync1{} -> return ()
    _ -> do
      putStringBE "CharLipSync"
      putStringBE "part2.lipsync"
  case ml of
    MagmaLipsync3{} -> do
      putStringBE "CharLipSync"
      putStringBE "part3.lipsync"
    _ -> return ()
  putStringBE "CharLipSync"
  putStringBE "song.lipsync"
  putByteString magmaMiloSuffix
  let putThenBarrier x = putLipsync x >> putWord32be 0xADDEADDE
  case ml of
    MagmaLipsync1 h1 -> do
      putThenBarrier h1
    MagmaLipsync2 h1 h2 -> do
      putThenBarrier h2
      putThenBarrier h1
    MagmaLipsync3 h1 h2 h3 -> do
      putThenBarrier h2
      putThenBarrier h3
      putThenBarrier h1

magmaMiloSuffix :: B.ByteString
magmaMiloSuffix = B.pack
  [ 0x00, 0x00, 0x00, 0x1B, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x3F, 0x35, 0x04, 0xF3, 0xBF, 0x35, 0x04, 0xF3
  , 0x00, 0x00, 0x00, 0x00, 0x3F, 0x13, 0xCD, 0x3A, 0x3F, 0x13, 0xCD, 0x3A, 0xBF, 0x13, 0xCD, 0x3A
  , 0x3E, 0xD1, 0x05, 0xEB, 0x3E, 0xD1, 0x05, 0xEB, 0x3F, 0x51, 0x05, 0xEB, 0xC3, 0xDD, 0xB3, 0xD7
  , 0xC3, 0xDD, 0xB3, 0xD7, 0x43, 0xDD, 0xB3, 0xD7, 0x00, 0x00, 0x00, 0x00, 0xBF, 0x80, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00, 0xC4, 0x40, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0xBF, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00, 0x44, 0x40, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xBF, 0x80, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x44, 0x40, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0xBF, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0xC4, 0x40, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0xC4, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xBF, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xBF, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x44, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xAD, 0xDE, 0xAD, 0xDE
  ]

data Lipsync = Lipsync
  { lipsyncVersion    :: Word32 -- 1 from magma v2
  , lipsyncSubversion :: Word32 -- 2 from magma v2
  , lipsyncDTAImport  :: B.ByteString -- empty string from magma v2
  , lipsyncVisemes    :: [B.ByteString]
  , lipsyncKeyframes  :: [Keyframe]
  } deriving (Eq, Show)

newtype Keyframe = Keyframe
  { keyframeEvents :: [VisemeEvent]
  } deriving (Eq, Show)

data VisemeEvent = VisemeEvent
  { visemeIndex  :: Int
  , visemeWeight :: Word8
  } deriving (Eq, Show)

getStringBE :: Get B.ByteString
getStringBE = do
  len <- getWord32be
  getByteString $ fromIntegral len

putStringBE :: B.ByteString -> Put
putStringBE bs = do
  putWord32be $ fromIntegral $ B.length bs
  putByteString bs

parseLipsync :: Get Lipsync
parseLipsync = do
  lipsyncVersion <- getWord32be
  lipsyncSubversion <- getWord32be
  lipsyncDTAImport <- getStringBE
  dtb <- getWord8
  case dtb of
    0 -> return ()
    _ -> fail "Parsing of Lipsync files with embedded DTB is not currently supported"
  skip 4 -- skips zeroes
  visemeCount <- getWord32be
  lipsyncVisemes <- replicateM (fromIntegral visemeCount) getStringBE
  keyframeCount <- getWord32be
  _followingSize <- getWord32be
  lipsyncKeyframes <- replicateM (fromIntegral keyframeCount) $ do
    eventCount <- getWord8
    keyframeEvents <- replicateM (fromIntegral eventCount) $ do
      visemeIndex <- fromIntegral <$> getWord8
      visemeWeight <- getWord8
      return VisemeEvent{..}
    return Keyframe{..}
  return Lipsync{..}

putLipsync :: Lipsync -> Put
putLipsync lip = do
  putWord32be $ lipsyncVersion lip
  putWord32be $ lipsyncSubversion lip
  putStringBE $ lipsyncDTAImport lip
  putWord8 0
  putWord32be 0
  putWord32be $ fromIntegral $ length $ lipsyncVisemes lip
  mapM_ putStringBE $ lipsyncVisemes lip
  putWord32be $ fromIntegral $ length $ lipsyncKeyframes lip
  let keyframeBS = runPut $ forM_ (lipsyncKeyframes lip) $ \key -> do
        putWord8 $ fromIntegral $ length $ keyframeEvents key
        forM_ (keyframeEvents key) $ \evt -> do
          putWord8 $ fromIntegral $ visemeIndex evt
          putWord8 $ visemeWeight evt
  putWord32be $ fromIntegral $ BL.length keyframeBS
  putLazyByteString keyframeBS
  putWord32be 0

lipsyncToMIDI :: U.TempoMap -> U.MeasureMap -> Lipsync -> RBFile.Song (RBFile.RawFile U.Beats)
lipsyncToMIDI tmap mmap lip = RBFile.Song tmap mmap $ RBFile.RawFile $ (:[])
  $ U.setTrackName "LIPSYNC"
  $ U.unapplyTempoTrack tmap
  $ RTB.flatten
  $ RTB.fromPairList
  $ do
    (dt, key) <- zip (0 : repeat (1/30 :: U.Seconds)) $ lipsyncKeyframes lip
    let evts = do
          vis <- keyframeEvents key
          let str = "[viseme " <> B8.unpack (lipsyncVisemes lip !! visemeIndex vis) <> " " <> show (visemeWeight vis) <> "]"
          return $ E.MetaEvent $ Meta.TextEvent str
    return (dt, evts)

autoLipsync :: VocalTrack U.Seconds -> Lipsync
autoLipsync vt = let
  edgesInFrames :: RTB.T NN.Int Bool
  edgesInFrames = removeDupes $ RTB.discretize $ RTB.mapTime (* 30) $
    RTB.normalize $ vocalTubes vt
  removeDupes (Wait dt _ (Wait 0 x rest)) = removeDupes $ Wait dt x rest
  removeDupes (Wait dt x rest)            = Wait dt x $ removeDupes rest
  removeDupes RNil                        = RNil
  ah True  = [(Viseme_Ox_hi, 255), (Viseme_Ox_lo, 255)]
  ah False = [(Viseme_Ox_hi, 0  ), (Viseme_Ox_lo, 0  )]
  makeKeyframes RNil             = [ah False]
  makeKeyframes (Wait 0  b rest) = [ah b] ++ drop 1 (makeKeyframes rest)
  makeKeyframes (Wait dt b rest) = replicate (NN.toNumber dt - 1) [] ++ [ah b] ++ makeKeyframes rest
  in Lipsync
    { lipsyncVersion    = 1
    , lipsyncSubversion = 2
    , lipsyncDTAImport  = B.empty
    , lipsyncVisemes    = map (B8.pack . drop 7 . show) [minBound :: MagmaViseme .. maxBound]
    , lipsyncKeyframes  = map
      (Keyframe . map ((\(vis, n) -> VisemeEvent (fromEnum vis) n)))
      (makeKeyframes $ edgesInFrames)
    }

lipsyncFromMidi :: LipsyncTrack U.Seconds -> Lipsync
lipsyncFromMidi _ = let
  -- TODO
  in Lipsync
    { lipsyncVersion    = 1
    , lipsyncSubversion = 2
    , lipsyncDTAImport  = B.empty
    , lipsyncVisemes    = map (B8.pack . drop 7 . show) [minBound :: MagmaViseme .. maxBound]
    , lipsyncKeyframes  = undefined
    }

data Venue = Venue
  { venueVersion    :: Word32
  , venueSubversion :: Word32
  , venueDTAImport  :: B.ByteString
  , venueMystery    :: B.ByteString
  , venueTracks     :: [Track]
  } deriving (Eq, Show)

data Track = Track
  { trackVersion    :: Word32
  , trackSubversion :: Word32
  , trackDomain     :: B.ByteString
  , trackMystery    :: B.ByteString
  , trackName       :: B.ByteString
  , trackMystery2   :: Word32
  , trackName2      :: B.ByteString
  , trackMystery3   :: B.ByteString
  , trackEvents     :: ATB.T U.Seconds B.ByteString
  } deriving (Eq, Show)

data VenueEvent = VenueEvent
  { venueEvent :: B.ByteString
  , venueTime  :: U.Seconds
  } deriving (Eq, Show)

parseVenue :: Get Venue
parseVenue = do
  venueVersion <- getWord32be -- 0xD
  venueSubversion <- getWord32be -- 0x2
  venueDTAImport <- getStringBE -- "song_anim"
  venueMystery <- getByteString 17
    {-
      00
      00 00 00 00
      00 00 00 04
      46 6D F5 79 -- probably end timestamp
      00 00 00 01
    -}
  trackCount <- getWord32be
  venueTracks <- replicateM (fromIntegral trackCount) $ do
    trackVersion <- getWord32be -- usually 6, 2 in postproc track
    trackSubversion <- getWord32be -- usually 6, 2 in postproc track
    trackDomain <- getStringBE -- "BandDirector"
    trackMystery <- getByteString 11 -- 01 00 01 00 00 00 00 00 00 00 05
    trackName <- getStringBE -- like "bass_intensity"
    trackMystery2 <- getWord32be
    trackName2 <- getStringBE -- like "lightpreset_interp" but usually ""
    trackMystery3 <- getByteString 5
    eventCount <- getWord32be
    trackEvents <- fmap ATB.fromPairList $ replicateM (fromIntegral eventCount) $ do
      event <- getStringBE
      -- see "postproc" track where each event has 4 extra bytes of 0
      event' <- if B.null event then getStringBE else return event
      frames <- getFloat32be
      return (realToFrac $ frames / 30, event')
    return Track{..}
  return Venue{..}

venueToMIDI :: U.TempoMap -> U.MeasureMap -> Venue -> RBFile.Song (RBFile.RawFile U.Beats)
venueToMIDI tmap mmap venue = RBFile.Song tmap mmap $ RBFile.RawFile $ do
  trk <- venueTracks venue
  return
    $ U.setTrackName (B8.unpack $ trackName trk)
    $ U.unapplyTempoTrack tmap
    $ RTB.fromAbsoluteEventList
    $ fmap (E.MetaEvent . Meta.TextEvent . B8.unpack)
    $ trackEvents trk

testConvertVenue :: FilePath -> FilePath -> FilePath -> IO ()
testConvertVenue fmid fven fout = do
  res <- logStdout $ stackIO (Load.fromFile fmid) >>= RBFile.readMIDIFile'
  mid <- case res of
    Left err  -> error $ show err
    Right mid -> return mid
  ven <- fmap (runGet parseVenue) $ BL.readFile fven
  let raw = venueToMIDI (RBFile.s_tempos mid) (RBFile.s_signatures mid) ven `asTypeOf` mid
  Save.toFile fout $ RBFile.showMIDIFile' raw

testConvertLipsync :: FilePath -> FilePath -> FilePath -> IO ()
testConvertLipsync fmid fvoc fout = do
  res <- logStdout $ stackIO (Load.fromFile fmid) >>= RBFile.readMIDIFile'
  mid <- case res of
    Left err  -> error $ show err
    Right mid -> return mid
  voc <- fmap (runGet parseLipsync) $ BL.readFile fvoc
  let raw = lipsyncToMIDI (RBFile.s_tempos mid) (RBFile.s_signatures mid) voc `asTypeOf` mid
  Save.toFile fout $ RBFile.showMIDIFile' raw
