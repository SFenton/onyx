{-# LANGUAGE GeneralizedNewtypeDeriving, DeriveDataTypeable, FlexibleContexts #-}
module Main where

import Development.Shake hiding ((%>))
import qualified Development.Shake as Shake
import Development.Shake.FilePath
import Development.Shake.Classes
import YAMLTree
import Config
import Audio
import OneFoot
import Magma
import qualified Data.Aeson as A
import Control.Applicative ((<$>), (<|>))
import Control.Monad (forM_, when, guard)
import Data.Maybe (fromMaybe, mapMaybe, listToMaybe)
import Data.List (isPrefixOf, sort)
import Scripts.Main
import qualified Sound.Jammit.Base as J
import qualified Sound.Jammit.Export as J
import qualified System.Directory as Dir
import qualified System.Environment as Env
import System.Exit (ExitCode(ExitSuccess))
import qualified System.Info as Info
import System.Process (readProcessWithExitCode)
import qualified Data.Conduit.Audio as CA

import qualified Data.DTA as D
import qualified Data.DTA.Serialize as D
import qualified Data.DTA.Serialize.RB3 as D
import qualified Data.DTA.Serialize.Magma as Magma
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString as B
import qualified Data.Map as Map
import qualified Data.HashMap.Strict as HM
import qualified Data.Traversable as T

import qualified Sound.MIDI.File as F
import qualified Sound.MIDI.File.Load as Load
import qualified Sound.MIDI.File.Save as Save

import Codec.Picture
import Codec.Picture.Types
import Data.Bits (shiftR)

jammitLib :: IO J.Library
jammitLib = do
  env <- Env.lookupEnv "JAMMIT"
  def <- J.findJammitDir
  case env <|> def of
    Nothing  -> error "jammitDir: couldn't find Jammit directory"
    Just dir -> J.loadLibrary dir

jammitTitle :: Song -> String
jammitTitle s = fromMaybe (_title s) (_jammitTitle s)

jammitArtist :: Song -> String
jammitArtist s = fromMaybe (_artist s) (_jammitArtist s)

jammitSearch :: String -> String -> Action String
jammitSearch title artist
  = show
  . J.getAudioParts
  . J.exactSearchBy J.title title
  . J.exactSearchBy J.artist artist
  <$> liftIO jammitLib

jammitRules :: Song -> Rules ()
jammitRules s = do
  let jTitle  = jammitTitle s
      jArtist = jammitArtist s
      jSearch :: Action [(J.AudioPart, FilePath)]
      jSearch = fmap read $ askOracle $ JammitResults (jTitle, jArtist)
      jSearchInstrument :: J.Instrument -> Action [FilePath]
      jSearchInstrument inst = do
        audios <- jSearch
        let parts = [ J.Only p | p <- [minBound .. maxBound], J.partToInstrument p == inst ]
        return $ mapMaybe (`lookup` audios) parts
  forM_ ["1p", "2p"] $ \feet -> do
    let dir = "gen/jammit" </> feet
    dir </> "drums_untimed.wav" %> \out -> do
      audios <- jSearchInstrument J.Drums
      case audios of
        [] -> buildAudio (Silence 2 $ CA.Seconds 0) out
        _  -> liftIO $ J.runAudio audios [] out
    dir </> "bass_untimed.wav" %> \out -> do
      audios <- jSearchInstrument J.Bass
      case audios of
        [] -> buildAudio (Silence 2 $ CA.Seconds 0) out
        _  -> liftIO $ J.runAudio audios [] out
    dir </> "guitar_untimed.wav" %> \out -> do
      audios <- jSearchInstrument J.Guitar
      case audios of
        [] -> buildAudio (Silence 2 $ CA.Seconds 0) out
        _  -> liftIO $ J.runAudio audios [] out
    dir </> "song_untimed.wav" %> \out -> do
      audios <- jSearch
      let backs = do
            (jpart, rbpart) <-
              -- listed in order of backing preference
              [ (J.Drums , Drums  )
              , (J.Bass  , Bass   )
              , (J.Guitar, Guitar )
              ]
            guard $ rbpart `elem` _config s
            case lookup (J.Without jpart) audios of
              Nothing    -> []
              Just audio -> [(rbpart, audio)]
      case backs of
        [] -> fail "No Jammit instrument package used in this song was found."
        (rbpart, back) : _ -> flip buildAudio out $ Mix $ concat
          [ [ Input $ JammitAIFC back ]
          , [ Gain (-1) $ Input $ Sndable $ dir </> "drums_untimed.wav"
            | rbpart /= Drums && elem Drums (_config s)
            ]
          , [ Gain (-1) $ Input $ Sndable $ dir </> "bass_untimed.wav"
            | rbpart /= Bass && elem Bass (_config s)
            ]
          , [ Gain (-1) $ Input $ Sndable $ dir </> "guitar_untimed.wav"
            | rbpart /= Guitar && elem Guitar (_config s)
            ]
          ]
    forM_ ["drums", "bass", "guitar", "song"] $ \part -> do
      dir </> (part ++ ".wav") %> \out -> do
        let untimed = Sndable $ dropExtension out ++ "_untimed.wav"
        case HM.lookup "jammit" $ _audio s of
          Nothing -> fail "No jammit audio configuration"
          Just (AudioSimple aud) ->
            buildAudio (fmap (const untimed) aud) out
          Just (AudioStems _) ->
            fail "jammit audio configuration is stems (unsupported)"

simpleRules :: Song -> Rules ()
simpleRules s = do
  forM_ [ (src, aud) | (src, AudioSimple aud) <- HM.toList $ _audio s, src /= "jammit" ] $ \(src, aud) -> do
    forM_ ["1p", "2p"] $ \feet -> do
      let dir = "gen" </> src </> feet
      forM_ ["drums.wav", "bass.wav", "guitar.wav"] $ \inst -> do
        dir </> inst %> buildAudio (Silence 2 $ CA.Seconds 0)
      dir </> "song.wav" %> \out -> do
        let pat = "audio-" ++ src ++ ".*"
        ls <- getDirectoryFiles "" [pat]
        case ls of
          []    -> fail $ "No file found matching pattern " ++ pat
          f : _ -> buildAudio (fmap (const $ Sndable f) aud) out

stemsRules :: Song -> Rules ()
stemsRules s = do
  forM_ [ (src, amap) | (src, AudioStems amap) <- HM.toList $ _audio s ] $ \(src, amap) -> do
    forM_ ["1p", "2p"] $ \feet -> do
      let dir = "gen" </> src </> feet
      forM_ (HM.toList amap) $ \(inst, aud) -> do
        dir </> (inst <.> "wav") %> \out -> do
          aud' <- T.forM aud $ \f -> let
            findMatch fp = do
              let pat = fp -<.> "*"
              ls <- getDirectoryFiles "" [pat]
              case ls of
                []     -> fail $ "No file found matching pattern " ++ pat
                f' : _ -> return f'
            in case f of
              Sndable    fp -> Sndable    <$> findMatch fp
              Rate r     fp -> Rate r     <$> findMatch fp
              JammitAIFC fp -> JammitAIFC <$> findMatch fp -- shouldn't happen
          buildAudio aud' out

eachAudio :: (Monad m) => Song -> (String -> m ()) -> m ()
eachAudio = forM_ . HM.keys . _audio

-- | The given function should accept the version title and directory.
eachVersion :: (Monad m) => Song -> (String -> FilePath -> m ()) -> m ()
eachVersion s f = eachAudio s $ \src ->
  forM_ [("1p", ""), ("2p", " (2x Bass Pedal)")] $ \(feet, titleSuffix) ->
    f (_title s ++ titleSuffix) ("gen" </> src </> feet)

countinRules :: Song -> Rules ()
countinRules s = eachVersion s $ \_ dir -> do
  dir </> "countin.wav" %> \out -> do
    let mid = dir </> "notes.mid"
        hit = _fileCountin s
    makeCountin mid hit out
  dir </> "song-countin.wav" %> \out -> do
    let song = Input $ Sndable $ dir </> "song.wav"
        countin = Input $ Sndable $ dir </> "countin.wav"
    buildAudio (Mix [song, countin]) out

oggRules :: Song -> Rules ()
oggRules s = eachVersion s $ \_ dir -> do
  dir </> "audio.ogg" %> \out -> do
    let drums = Input $ Sndable $ dir </> "drums.wav"
        bass  = Input $ Sndable $ dir </> "bass.wav"
        guitar = Input $ Sndable $ dir </> "guitar.wav"
        song  = Input $ Sndable $ dir </> "song-countin.wav"
        audio = Merge $ let
          parts = concat
            [ [drums | Drums `elem` _config s]
            , [bass | Bass `elem` _config s]
            , [guitar | Guitar `elem` _config s]
            , [song]
            ]
          in if length parts == 3
            then parts ++ [Silence 1 $ CA.Seconds 0]
            -- the Silence is to work around oggenc bug:
            -- it assumes 6 channels is 5.1 surround where the last channel
            -- is LFE, so instead we add a silent 7th channel
            else parts
    buildAudio audio out
  dir </> "audio.mogg" %> \mogg -> do
    let ogg = mogg -<.> "ogg"
    need [ogg]
    liftIO $ oggToMogg ogg mogg

-- | Makes the (low-quality) audio files for the online preview app.
crapRules :: Rules ()
crapRules = do
  let src = "gen/album/2p/song-countin.wav"
      preview ext = "gen/album/2p/preview-audio" <.> ext
  preview "wav" %> \out -> do
    need [src]
    cmd "sox" [src, out] "remix 1,2"
  preview "mp3" %> \out -> do
    need [preview "wav"]
    cmd "lame" [preview "wav", out] "-b 16"
  preview "ogg" %> \out -> do
    need [preview "wav"]
    cmd "oggenc -b 16 --resample 16000 -o" [out, preview "wav"]

midRules :: Song -> Rules ()
midRules s = eachAudio s $ \src -> do
  let mid1p = "gen" </> src </> "1p/notes.mid"
      mid2p = "gen" </> src </> "2p/notes.mid"
      mid   = "gen" </> src </> "notes.mid"
  mid %> \out -> do
    need ["notes.mid"]
    let tempos = "tempo-" ++ src ++ ".mid"
    b <- doesFileExist tempos
    if b
      then replaceTempos "notes.mid" tempos out
      else runMidi fixResolution "notes.mid" out
  mid2p %> runMidi
    (fixRolls . autoBeat . drumMix 0 . tempoTrackName)
    mid
  mid1p %> runMidi (oneFoot 0.18 0.11) mid2p

runMidi :: (F.T -> F.T) -> FilePath -> FilePath -> Action ()
runMidi f fin fout = do
  need [fin]
  liftIO $ Load.fromFile fin >>= Save.toFile fout . f

newtype JammitResults = JammitResults (String, String)
  deriving (Show, Typeable, Eq, Hashable, Binary, NFData)

-- | Wraps the Shake operator to also install a dependency on song.yml.
(%>) :: FilePattern -> (FilePath -> Action ()) -> Rules ()
pat %> f = pat Shake.%> \out -> do
  need ["song.yml"]
  f out
infix 1 %>

main :: IO ()
main = do
  yaml <- readYAMLTree "song.yml"
  case A.fromJSON yaml of
    A.Error s -> fail s
    A.Success song -> do
      shakeArgs shakeOptions $ do
        _ <- addOracle $ \(JammitResults (title, artist)) ->
          jammitSearch title artist
        phony "clean" $ cmd "rm -rf gen"
        midRules song
        jammitRules song
        simpleRules song
        stemsRules song
        countinRules song
        oggRules song
        coverRules song
        rb3Rules song
        magmaRules song
        fofRules song
        crapRules
      e <-     Dir.doesDirectoryExist       "gen/temp"
      when e $ Dir.removeDirectoryRecursive "gen/temp"

packageID :: FilePath -> Song -> String
packageID dir s = let
  buildID = hash (_title s, _artist s, dir) `mod` 1000000000
  in "onyx" ++ show buildID

rb3Rules :: Song -> Rules ()
rb3Rules s = eachVersion s $ \title dir -> do
  let pkg = packageID dir s
      pathDta = dir </> "rb3/songs/songs.dta"
      pathMid = dir </> "rb3/songs" </> pkg </> (pkg <.> "mid")
      pathMogg = dir </> "rb3/songs" </> pkg </> (pkg <.> "mogg")
      pathPng = dir </> "rb3/songs" </> pkg </> "gen" </> (pkg ++ "_keep.png_xbox")
      pathCon = dir </> "rb3.con"
  pathDta %> \out -> do
    songPkg <- makeDTA pkg title (dir </> "notes.mid") s
    let dta = D.DTA 0 $ D.Tree 0 $ (:[]) $ D.Parens $ D.Tree 0 $
          D.Key (B8.pack pkg) : D.toChunks songPkg
    writeFile' out $ D.sToDTA dta
  pathMid %> copyFile' (dir </> "notes.mid")
  pathMogg %> copyFile' (dir </> "audio.mogg")
  pathPng %> copyFile' "gen/cover.png_xbox"
  pathCon %> \out -> do
    need [pathDta, pathMid, pathMogg, pathPng]
    cmd "rb3pkg -p" [_artist s ++ ": " ++ _title s] "-d"
      ["Version: " ++ drop 4 dir] "-f" [dir </> "rb3"] out

makeDTA :: String -> String -> FilePath -> Song -> Action D.SongPackage
makeDTA pkg title mid s = do
  (pstart, pend) <- previewBounds mid
  len <- songLength mid
  let numChannels = length (_config s) * 2 + 2
  return D.SongPackage
    { D.name = B8.pack title
    , D.artist = B8.pack $ _artist s
    , D.master = True
    , D.songId = Right $ D.Keyword $ B8.pack pkg
    , D.song = D.Song
      { D.songName = B8.pack $ "songs/" ++ pkg ++ "/" ++ pkg
      , D.tracksCount = Just $ D.InParens
        [ if Drums `elem` _config s then 2 else 0
        , if Bass `elem` _config s then 2 else 0
        , if Guitar `elem` _config s then 2 else 0
        , 0
        , 0
        , 2
        ]
      , D.tracks = D.InParens $ D.Dict $ Map.fromList $ let
        channelNums = zip [0..] $ concatMap (\x -> [x, x]) $ sort $ _config s
        -- ^ the sort is important
        channelNumsFor inst = [ i | (i, inst') <- channelNums, inst == inst' ]
        trackDrum = (B8.pack "drum", Right $ D.InParens $ channelNumsFor Drums)
        trackBass = (B8.pack "bass", Right $ D.InParens $ channelNumsFor Bass)
        trackGuitar = (B8.pack "guitar", Right $ D.InParens $ channelNumsFor Guitar)
        in concat
          [ [trackDrum | Drums `elem` _config s]
          , [trackBass | Bass `elem` _config s]
          , [trackGuitar | Guitar `elem` _config s]
          ]
      , D.vocalParts = 0
      , D.pans = D.InParens $ take numChannels $ cycle [-1, 1]
      , D.vols = D.InParens $ replicate numChannels 0
      , D.cores = D.InParens $ replicate numChannels (-1)
      , D.drumSolo = D.DrumSounds $ D.InParens $ map (D.Keyword . B8.pack) $ words
        "kick.cue snare.cue tom1.cue tom2.cue crash.cue"
      , D.drumFreestyle = D.DrumSounds $ D.InParens $ map (D.Keyword . B8.pack) $ words
        "kick.cue snare.cue hat.cue ride.cue crash.cue"
      }
    , D.bank = Just $ Left $ B8.pack "sfx/tambourine_bank.milo"
    , D.drumBank = Nothing
    , D.animTempo = Left D.KTempoMedium
    , D.bandFailCue = Nothing
    , D.songScrollSpeed = 2300
    , D.preview = (fromIntegral pstart, fromIntegral pend)
    , D.songLength = fromIntegral len
    , D.rank = D.Dict $ Map.fromList
      [ (B8.pack "drum", if Drums `elem` _config s then 1 else 0)
      , (B8.pack "bass", if Bass `elem` _config s then 1 else 0)
      , (B8.pack "guitar", if Guitar `elem` _config s then 1 else 0)
      , (B8.pack "vocals", 0)
      , (B8.pack "keys", 0)
      , (B8.pack "real_keys", 0)
      , (B8.pack "band", 1)
      ]
    , D.solo = Nothing
    , D.format = 10
    , D.version = 30
    , D.gameOrigin = D.Keyword $ B8.pack "ugc_plus"
    , D.rating = 4
    , D.genre = D.Keyword $ B8.pack $ _genre s
    , D.subGenre = Just $ D.Keyword $ B8.pack $ "subgenre_" ++ _subgenre s
    , D.vocalGender = case _vocalGender s of
      Just Male   -> Magma.Male
      Just Female -> Magma.Female
      Nothing     -> Magma.Female
    , D.shortVersion = Nothing
    , D.yearReleased = fromIntegral $ _year s
    , D.albumArt = Just True
    , D.albumName = Just $ B8.pack $ _album s
    , D.albumTrackNumber = Just $ fromIntegral $ _trackNumber s
    , D.vocalTonicNote = Nothing
    , D.songTonality = Nothing
    , D.tuningOffsetCents = Just 0
    , D.realGuitarTuning = Nothing
    , D.realBassTuning = Nothing
    , D.guidePitchVolume = Just (-3)
    , D.encoding = Just $ D.Keyword $ B8.pack "latin1"
    }

-- | Find an ImageMagick binary, because the names are way too generic, and
-- \"convert\" is both an ImageMagick program and a Windows built-in utility.
imageMagick :: String -> IO (Maybe String)
imageMagick icmd = do
  (code, _, _) <- readProcessWithExitCode icmd ["-version"] ""
  case code of
    ExitSuccess -> return $ Just icmd
    _ -> case Info.os of
      "mingw32" -> firstJustM $
        -- env variables for different configs of (ghc arch)/(imagemagick arch)
        -- ProgramFiles: 32/32 or 64/64
        -- ProgramFiles(x86): 64/32
        -- ProgramW6432: 32/64
        flip map ["ProgramFiles", "ProgramFiles(x86)", "ProgramW6432"] $ \env ->
          Env.lookupEnv env >>= \var -> case var of
            Nothing -> return Nothing
            Just pf
              ->  fmap (\im -> pf </> im </> icmd)
              .   listToMaybe
              .   filter ("ImageMagick" `isPrefixOf`)
              <$> Dir.getDirectoryContents pf
      _ -> return Nothing

-- | Only runs actions until the first that gives 'Just'.
firstJustM :: (Monad m) => [m (Maybe a)] -> m (Maybe a)
firstJustM [] = return Nothing
firstJustM (mx : xs) = mx >>= \x -> case x of
  Nothing -> firstJustM xs
  Just y  -> return $ Just y

anyToRGB8 :: DynamicImage -> Image PixelRGB8
anyToRGB8 dyn = case dyn of
  ImageY8 i -> promoteImage i
  ImageY16 i -> anyToRGB8 $ ImageRGB16 $ promoteImage i
  ImageYF i -> anyToRGB8 $ ImageRGBF $ promoteImage i
  ImageYA8 i -> promoteImage i
  ImageYA16 i -> anyToRGB8 $ ImageRGBA16 $ promoteImage i
  ImageRGB8 i -> i
  ImageRGB16 i -> pixelMap (\(PixelRGB16 r g b) -> PixelRGB8 (f r) (f g) (f b)) i
    where f w16 = fromIntegral $ w16 `shiftR` 8
  ImageRGBF i -> pixelMap (\(PixelRGBF r g b) -> PixelRGB8 (f r) (f g) (f b)) i
    where f w16 = floor $ min 0x100 $ w16 * 0x100
  ImageRGBA8 i -> dropAlphaLayer i
  ImageRGBA16 i -> anyToRGB8 $ ImageRGB16 $ dropAlphaLayer i
  ImageYCbCr8 i -> convertImage i
  ImageCMYK8 i -> convertImage i
  ImageCMYK16 i -> anyToRGB8 $ ImageRGB16 $ convertImage i

scaleBilinear :: (Pixel a, Integral (PixelBaseComponent a)) => Int -> Int -> Image a -> Image a
scaleBilinear w' h' img = generateImage f w' h' where
  f x' y' = let
    x, y :: Double
    x = fromIntegral x' / fromIntegral (w' - 1) * fromIntegral (imageWidth  img - 1)
    y = fromIntegral y' / fromIntegral (h' - 1) * fromIntegral (imageHeight img - 1)
    in case (properFraction x, properFraction y) of
      ((xi, 0 ), (yi, 0 )) -> pixelAt img xi yi
      ((xi, 0 ), (yi, yf)) -> let
        g _ c1 c2 = round $ fromIntegral c1 * (1 - yf) + fromIntegral c2 * yf
        in mixWith g (pixelAt img xi yi) (pixelAt img xi (yi + 1))
      ((xi, xf), (yi, 0 )) -> let
        g _ c1 c2 = round $ fromIntegral c1 * (1 - xf) + fromIntegral c2 * xf
        in mixWith g (pixelAt img xi yi) (pixelAt img (xi + 1) yi)
      ((xi, xf), (yi, yf)) -> let
        g1 _ c1 c2 = round $ fromIntegral c1 * (1 - xf) + fromIntegral c2 * xf
        g2 _ c1 c2 = round $ fromIntegral c1 * (1 - yf) + fromIntegral c2 * yf
        in mixWith g2
          (mixWith g1 (pixelAt img xi yi) (pixelAt img (xi + 1) yi))
          (mixWith g1 (pixelAt img xi (yi + 1)) (pixelAt img (xi + 1) (yi + 1)))

coverRules :: Song -> Rules ()
coverRules s = do
  let img = _fileAlbumArt s
  "gen/cover.bmp" %> \out -> do
    need [img]
    res <- liftIO $ readImage img
    case res of
      Left err -> fail $ "Failed to load cover art: " ++ err
      Right dyn -> liftIO $ writeBitmap out $ scaleBilinear 256 256 $ anyToRGB8 dyn
  "gen/cover.png" %> \out -> do
    need [img]
    res <- liftIO $ readImage img
    case res of
      Left err -> fail $ "Failed to load cover art: " ++ err
      Right dyn -> liftIO $ writePng out $ scaleBilinear 256 256 $ anyToRGB8 dyn
  "gen/cover.dds" %> \out -> do
    need [img]
    conv <- liftIO $ imageMagick "convert"
    case conv of
      Nothing -> fail "coverRules: couldn't find ImageMagick convert"
      Just c  -> cmd [c] [img] "-resize 256x256!" [out]
  "gen/cover.png_xbox" %> \out -> do
    let dds = out -<.> "dds"
    need [dds]
    b <- liftIO $ B.readFile dds
    let header =
          [ 0x01, 0x04, 0x08, 0x00, 0x00, 0x00, 0x04, 0x00
          , 0x01, 0x00, 0x01, 0x80, 0x00, 0x00, 0x00, 0x00
          , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
          , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
          ]
        bytes = B.unpack $ B.drop 0x80 b
        flipPairs (x : y : xs) = y : x : flipPairs xs
        flipPairs _ = []
        b' = B.pack $ header ++ flipPairs bytes
    liftIO $ B.writeFile out b'

magmaRules :: Song -> Rules ()
magmaRules s = eachVersion s $ \title dir -> do
  let drums = dir </> "magma/drums.wav"
      bass = dir </> "magma/bass.wav"
      guitar = dir </> "magma/guitar.wav"
      song = dir </> "magma/song-countin.wav"
      cover = dir </> "magma/cover.bmp"
      mid = dir </> "magma/notes.mid"
      proj = dir </> "magma/magma.rbproj"
      rba = dir </> "magma.rba"
  drums %> copyFile' (dir </> "drums.wav")
  bass %> copyFile' (dir </> "bass.wav")
  guitar %> copyFile' (dir </> "guitar.wav")
  song %> copyFile' (dir </> "song-countin.wav")
  cover %> copyFile' "gen/cover.bmp"
  mid %> magmaClean (dir </> "notes.mid")
  proj %> \out -> do
    let pkg = packageID dir s
    p <- makeMagmaProj pkg title (dir </> "notes.mid") s
    let dta = D.DTA 0 $ D.Tree 0 $ D.toChunks p
    writeFile' out $ D.sToDTA dta
  rba %> \_ -> do
    when (Drums `elem` _config s) $ need [drums]
    when (Bass `elem` _config s) $ need [bass]
    when (Guitar `elem` _config s) $ need [guitar]
    need [song, cover, mid, proj]
    liftIO $ runMagma proj rba

makeMagmaProj :: String -> String -> FilePath -> Song -> Action Magma.RBProj
makeMagmaProj pkg title mid s = do
  (pstart, _) <- previewBounds mid
  let emptyDryVox = Magma.DryVoxPart
        { Magma.dryVoxFile = B8.pack ""
        , Magma.dryVoxEnabled = True
        }
      emptyAudioFile = Magma.AudioFile
        { Magma.audioEnabled = False
        , Magma.channels = 0
        , Magma.pan = []
        , Magma.vol = []
        , Magma.audioFile = B8.pack ""
        }
      stereoFile f = Magma.AudioFile
        { Magma.audioEnabled = True
        , Magma.channels = 2
        , Magma.pan = [-1, 1]
        , Magma.vol = [0, 0]
        , Magma.audioFile = B8.pack f
        }
  return Magma.RBProj
    { Magma.project = Magma.Project
      { Magma.toolVersion = B8.pack "110411_A"
      , Magma.projectVersion = 24
      , Magma.metadata = Magma.Metadata
        { Magma.songName = B8.pack title
        , Magma.artistName = B8.pack $ _artist s
        , Magma.genre = D.Keyword $ B8.pack $ _genre s
        , Magma.subGenre = D.Keyword $ B8.pack $ "subgenre_" ++ _subgenre s
        , Magma.yearReleased = fromIntegral $ _year s
        , Magma.albumName = B8.pack $ _album s
        , Magma.author = B8.pack "Onyxite"
        , Magma.releaseLabel = B8.pack "Onyxite Customs"
        , Magma.country = D.Keyword $ B8.pack "ugc_country_us"
        , Magma.price = 160
        , Magma.trackNumber = fromIntegral $ _trackNumber s
        , Magma.hasAlbum = True
        }
      , Magma.gamedata = Magma.Gamedata
        { Magma.previewStartMs = fromIntegral pstart
        , Magma.rankDrum = 1
        , Magma.rankBass = 1
        , Magma.rankGuitar = 1
        , Magma.rankVocals = 1
        , Magma.rankKeys = 1
        , Magma.rankProKeys = 1
        , Magma.rankBand = 1
        , Magma.vocalScrollSpeed = 2300
        , Magma.animTempo = 32
        , Magma.vocalGender = case _vocalGender s of
          Just Male   -> Magma.Male
          Just Female -> Magma.Female
          Nothing     -> Magma.Female
        , Magma.vocalPercussion = Magma.Tambourine
        , Magma.vocalParts = 0
        , Magma.guidePitchVolume = -3
        }
      , Magma.languages = Magma.Languages
        { Magma.english = True
        , Magma.french = False
        , Magma.italian = False
        , Magma.spanish = False
        , Magma.german = False
        , Magma.japanese = False
        }
      , Magma.destinationFile = B8.pack $ pkg <.> "rba"
      , Magma.midi = Magma.Midi
        { Magma.midiFile = B8.pack "notes.mid"
        , Magma.autogenTheme = Right $ B8.pack ""
        }
      , Magma.dryVox = Magma.DryVox
        { Magma.part0 = emptyDryVox
        , Magma.part1 = emptyDryVox
        , Magma.part2 = emptyDryVox
        , Magma.tuningOffsetCents = 0
        }
      , Magma.albumArt = Magma.AlbumArt $ B8.pack "cover.bmp"
      , Magma.tracks = Magma.Tracks
        { Magma.drumLayout = Magma.Kit
        , Magma.drumKit = if Drums `elem` _config s
          then stereoFile "drums.wav"
          else emptyAudioFile
        , Magma.drumKick = emptyAudioFile
        , Magma.drumSnare = emptyAudioFile
        , Magma.bass = if Bass `elem` _config s
          then stereoFile "bass.wav"
          else emptyAudioFile
        , Magma.guitar = if Guitar `elem` _config s
          then stereoFile "guitar.wav"
          else emptyAudioFile
        , Magma.vocals = emptyAudioFile
        , Magma.keys = emptyAudioFile
        , Magma.backing = stereoFile "song-countin.wav"
        }
      }
    }

fofRules :: Song -> Rules ()
fofRules s = eachVersion s $ \title dir -> do
  let mid = dir </> "fof/notes.mid"
      png = dir </> "fof/album.png"
      drums = dir </> "fof/drums.ogg"
      bass = dir </> "fof/rhythm.ogg"
      guitar = dir </> "fof/guitar.ogg"
      song = dir </> "fof/song.ogg"
      ini = dir </> "fof/song.ini"
  mid %> copyFile' (dir </> "notes.mid")
  png %> copyFile' "gen/cover.png"
  drums %> buildAudio (Input $ Sndable $ dir </> "drums.wav")
  bass %> buildAudio (Input $ Sndable $ dir </> "bass.wav")
  guitar %> buildAudio (Input $ Sndable $ dir </> "guitar.wav")
  song %> buildAudio (Input $ Sndable $ dir </> "song-countin.wav")
  ini %> \out -> makeIni title mid s >>= writeFile' out
  phony (dir </> "fof-all") $ do
    need [mid, png, song, ini]
    when (Drums `elem` _config s) $ need [drums]
    when (Bass `elem` _config s) $ need [bass]
    when (Guitar `elem` _config s) $ need [guitar]

makeIni :: String -> FilePath -> Song -> Action String
makeIni title mid s = do
  len <- songLength mid
  let iniLines =
        [ ("name", title)
        , ("artist", _artist s)
        , ("album", _album s)
        , ("genre", _genre s)
        , ("year", show $ _year s)
        , ("song_length", show len)
        , ("charter", "Onyxite")
        , ("diff_band", "0")
        , ("diff_drums", if Drums `elem` _config s then "0" else "-1")
        , ("diff_bass", if Bass `elem` _config s then "0" else "-1")
        , ("diff_guitar", if Guitar `elem` _config s then "0" else "-1")
        , ("diff_vocals", "-1")
        , ("diff_keys", "-1")
        ]
      makeLine (x, y) = x ++ " = " ++ y
  return $ unlines $ "[song]" : map makeLine iniLines
