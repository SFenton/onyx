{- |
Common import functions for RB1, RB2, RB3, TBRB
-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}
module Import.RockBand where

import           ArkTool                        (ark_DecryptVgs)
import           Audio                          (Audio (..), Edge (..))
import           Codec.Picture.Types            (dropTransparency, pixelMap)
import           Config
import           Control.Applicative            ((<|>))
import           Control.Arrow                  (second)
import           Control.Concurrent.Async       (forConcurrently)
import           Control.Monad                  (forM, forM_, guard, unless,
                                                 when)
import           Control.Monad.Codec.Onyx       (req)
import           Control.Monad.IO.Class         (MonadIO)
import           Control.Monad.Trans.StackTrace
import           Data.Binary.Codec.Class        (bin, codecIn, (=.))
import qualified Data.ByteString                as B
import qualified Data.ByteString.Char8          as B8
import qualified Data.ByteString.Lazy           as BL
import qualified Data.Conduit.Audio             as CA
import           Data.Default.Class             (def)
import qualified Data.DTA                       as D
import qualified Data.DTA.Serialize             as D
import           Data.DTA.Serialize.Magma       (Gender (..))
import qualified Data.DTA.Serialize.RB3         as D
import           Data.Foldable                  (toList)
import qualified Data.HashMap.Strict            as HM
import           Data.List.Extra                (elemIndex, nubOrd, (\\))
import           Data.List.NonEmpty             (NonEmpty (..))
import qualified Data.List.NonEmpty             as NE
import qualified Data.Map                       as Map
import           Data.Maybe                     (catMaybes, fromMaybe, isJust,
                                                 mapMaybe)
import           Data.SimpleHandle              (Folder (..), Readable,
                                                 byteStringSimpleHandle,
                                                 fileReadable, findByteString,
                                                 findFileCI, handleToByteString,
                                                 makeHandle, splitPath,
                                                 useHandle)
import qualified Data.Text                      as T
import           Data.Text.Encoding             (decodeLatin1, decodeUtf8With)
import qualified Data.Text.Encoding             as TE
import           Data.Text.Encoding.Error       (lenientDecode)
import           Difficulty
import           GuitarHeroII.Audio             (splitOutVGSChannels,
                                                 vgsChannelCount)
import           Import.Base
import           Magma                          (rbaContents)
import           PlayStation.PSS                (extractVGSStream,
                                                 extractVideoStream,
                                                 scanPackets)
import           PrettyDTA                      (C3DTAComments (..),
                                                 DTASingle (..), readDTASingles,
                                                 readDTBSingles)
import           Resources                      (rb3Updates)
import           RockBand.Codec.Drums           as RBDrums
import qualified RockBand.Codec.File            as RBFile
import           RockBand.Codec.File            (FlexPartName (..))
import           RockBand.Codec.ProGuitar       (GtrBase (..), GtrTuning (..))
import           RockBand.Common
import           RockBand.Milo                  (SongPref (..), decompressMilo,
                                                 miloToFolder, parseMiloFile)
import           RockBand.RB4.Image
import           RockBand.RB4.RBMid
import           RockBand.RB4.SongDTA
import qualified Sound.MIDI.File.Save           as Save
import qualified Sound.MIDI.Util                as U
import           STFS.Package                   (runGetM)
import qualified System.Directory               as Dir
import           System.FilePath                (takeDirectory, takeFileName,
                                                 (-<.>), (<.>), (</>))
import           System.IO.Temp                 (withSystemTempDirectory)
import           Text.Read                      (readMaybe)

data RBImport = RBImport
  { rbiSongPackage :: D.SongPackage
  , rbiComments    :: C3DTAComments
  , rbiMOGG        :: Maybe SoftContents
  , rbiPSS         :: Maybe (IO (SoftFile, [BL.ByteString])) -- if ps2, load video and vgs channels
  , rbiAlbumArt    :: Maybe SoftFile
  , rbiMilo        :: Maybe Readable
  , rbiMIDI        :: Readable
  , rbiMIDIUpdate  :: Maybe Readable
  , rbiSource      :: Maybe FilePath
  }

importSTFSFolder :: (SendMessage m, MonadIO m) => FilePath -> Folder T.Text Readable -> StackTraceT m [Import m]
importSTFSFolder src folder = do
  -- TODO support songs/gen/songs.dtb instead
  packSongs <- stackIO (findByteString ("songs" :| ["songs.dta"]) folder) >>= \case
    Nothing -> stackIO (findByteString ("songs" :| ["gen", "songs.dtb"]) folder) >>= \case
      Nothing -> fatal "Couldn't find songs/songs.dta or songs/gen/songs.dtb"
      Just bs -> readDTBSingles $ BL.toStrict bs
    Just bs -> readDTASingles $ BL.toStrict bs
  updateDir <- stackIO rb3Updates
  fmap catMaybes $ forM packSongs $ \(DTASingle top pkg comments, _) -> errorToWarning $ do
    let base = T.unpack $ D.songName $ D.song pkg
        split s = case splitPath $ T.pack s of
          Nothing -> fatal $ "Internal error, couldn't parse path: " <> show s
          Just p  -> return p
        need p = case findFileCI p folder of
          Just r  -> return r
          Nothing -> fatal $ "Required file not found: " <> T.unpack (T.intercalate "/" $ toList p)
    miloPath <- split $ takeDirectory base </> "gen" </> takeFileName base <.> "milo_xbox"
    moggPath <- split $ base <.> "mogg"
    pssPath  <- split $ base <.> "pss"
    midiPath <- split $ base <.> "mid"
    artPathXbox <- split $ takeDirectory base </> "gen" </> (takeFileName base ++ "_keep.png_xbox")
    artPathPS3 <- split $ takeDirectory base </> "gen" </> (takeFileName base ++ "_keep.png_ps3")

    let mogg = SoftReadable <$> findFileCI moggPath folder
        pss = case findFileCI pssPath folder of
          Nothing -> Nothing
          Just r -> Just $ do
            (bsVideo, bsVGS) <- useHandle r $ \h -> do
              packets <- scanPackets h
              vid <- extractVideoStream 0xE0 packets h
              vgs <- extractVGSStream   0xBD packets h
              return (vid, vgs)
            let rVideo = SoftReadable $ makeHandle "video.m2v" $ byteStringSimpleHandle bsVideo
            chans <- withSystemTempDirectory "decrypt-vgs" $ \temp -> do
              let enc = temp </> "enc.vgs"
                  dec = temp </> "dec.vgs"
                  rVGS = fileReadable dec
              BL.writeFile enc bsVGS
              ark_DecryptVgs dec enc >>= \b -> unless b $ fail "Couldn't decrypt VGS file"
              numChannels <- vgsChannelCount rVGS
              forConcurrently [0 .. numChannels - 1] $ \i -> do
                splitOutVGSChannels [i] rVGS
            return (SoftFile "video.m2v" rVideo, chans)

    midi <- need midiPath
    let missingArt = updateDir </> T.unpack top </> "gen" </> (T.unpack top ++ "_keep.png_xbox")
        updateMid = updateDir </> T.unpack top </> (T.unpack top ++ "_update.mid")
    art <- if fromMaybe False (D.albumArt pkg) || D.gameOrigin pkg == Just "beatles"
      then stackIO (Dir.doesFileExist missingArt) >>= \case
        -- if True, old rb1 song with album art on rb3 disc
        True -> return $ Just $ SoftFile "cover.png_xbox" $ SoftReadable $ fileReadable missingArt
        False -> case findFileCI artPathXbox folder of
          Just res -> return $ Just $ SoftFile "cover.png_xbox" $ SoftReadable res
          Nothing -> case findFileCI artPathPS3 folder of
            Just res -> return $ Just $ SoftFile "cover.png_ps3" $ SoftReadable res
            Nothing -> do
              warn $ "Expected album art, but didn't find it: " <> show artPathXbox
              return Nothing
      else return Nothing
    update <- if maybe False ("disc_update" `elem`) $ D.extraAuthoring pkg
      then stackIO (Dir.doesFileExist updateMid) >>= \case
        True -> return $ Just $ fileReadable updateMid
        False -> do
          warn $ "Expected to find disc update MIDI but it's not installed: " <> updateMid
          return Nothing
      else return Nothing
    return $ importRB RBImport
      { rbiSongPackage = pkg
      , rbiComments = comments
      , rbiMOGG = mogg
      , rbiPSS = pss
      , rbiAlbumArt = art
      , rbiMilo = findFileCI miloPath folder
      , rbiMIDI = midi
      , rbiMIDIUpdate = update
      , rbiSource = Just src
      }

importRBA :: (SendMessage m, MonadIO m) => FilePath -> Import m
importRBA rba level = do
  when (level == ImportFull) $ lg $ "Importing RBA from: " <> rba
  let contents = rbaContents rba
      need i = case lookup i contents of
        Just r  -> return r
        Nothing -> fatal $ "Required RBA subfile " <> show i <> " not found"
  packSongs <- need 0 >>= \r -> stackIO (useHandle r handleToByteString) >>= readDTASingles . BL.toStrict
  (DTASingle _top pkg comments, isUTF8) <- case packSongs of
    [song] -> return song
    _      -> fatal $ "Expected 1 song in RBA, found " <> show (length packSongs)
  midi <- need 1
  mogg <- SoftReadable <$> need 2
  milo <- need 3
  bmp <- SoftFile "cover.bmp" . SoftReadable <$> need 4
  extraBS <- need 6 >>= \r -> stackIO $ useHandle r handleToByteString
  extra <- fmap (if isUTF8 then decodeUtf8With lenientDecode else decodeLatin1)
    <$> D.readDTABytes (BL.toStrict extraBS)
  let author = case extra of
        D.DTA _ (D.Tree _ [D.Parens (D.Tree _
          ( D.String "backend"
          : D.Parens (D.Tree _ [D.Sym "author", D.String s])
          : _
          ))])
          -> Just s
        _ -> Nothing
      -- TODO: import more stuff from the extra dta
  importRB RBImport
    { rbiSongPackage = pkg
    , rbiComments = comments
      { c3dtaAuthoredBy = author
      }
    , rbiMOGG = Just mogg
    , rbiPSS = Nothing
    , rbiAlbumArt = Just bmp
    , rbiMilo = Just milo
    , rbiMIDI = midi
    , rbiMIDIUpdate = Nothing
    , rbiSource = Nothing
    } level

dtaIsRB3 :: D.SongPackage -> Bool
dtaIsRB3 pkg = maybe False (`elem` ["rb3", "rb3_dlc", "ugc_plus"]) $ D.gameOrigin pkg
  -- rbn1 songs have (game_origin rb2) (ugc 1)

dtaIsHarmonixRB3 :: D.SongPackage -> Bool
dtaIsHarmonixRB3 pkg = maybe False (`elem` ["rb3", "rb3_dlc"]) $ D.gameOrigin pkg

-- Time in seconds that the video/audio should start before the midi begins.
rockBandPS2PreSongTime :: (Fractional a) => D.SongPackage -> a
rockBandPS2PreSongTime pkg = if D.video pkg then 5 else 3

importRB :: (SendMessage m, MonadIO m) => RBImport -> Import m
importRB rbi level = do

  let pkg = rbiSongPackage rbi
      files2x = Nothing
      (title, auto2x) = determine2xBass $ D.name pkg
      is2x = fromMaybe auto2x $ c3dta2xBass $ rbiComments rbi
      hasKicks = if is2x then Kicks2x else Kicks1x

  when (level == ImportFull) $ forM_ (rbiSource rbi) $ \src -> do
    lg $ "Importing Rock Band song [" <> T.unpack (D.songName $ D.song pkg) <> "] from: " <> src

  (midiFixed, midiOnyx) <- case level of
    ImportFull -> do
      RBFile.Song temps sigs (RBFile.RawFile trks1x) <- RBFile.loadMIDIReadable $ rbiMIDI rbi
      trksUpdate <- case rbiMIDIUpdate rbi of
        Nothing -> return []
        Just umid -> RBFile.rawTracks . RBFile.s_tracks <$> RBFile.loadMIDIReadable umid
      let updatedNames = map Just $ mapMaybe U.trackName trksUpdate
          trksUpdated
            = filter ((`notElem` updatedNames) . U.trackName) trks1x
            ++ trksUpdate
      midiFixed <- fmap checkEnableDynamics $ RBFile.interpretMIDIFile $ RBFile.Song temps sigs trksUpdated
      return (midiFixed, midiFixed { RBFile.s_tracks = RBFile.fixedToOnyx $ RBFile.s_tracks midiFixed })
    ImportQuick -> return (emptyChart, emptyChart)

  drumkit <- case D.drumBank pkg of
    Nothing -> return HardRockKit
    Just x -> case x of
      "sfx/kit01_bank.milo" -> return HardRockKit
      "sfx/kit02_bank.milo" -> return ArenaKit
      "sfx/kit03_bank.milo" -> return VintageKit
      "sfx/kit04_bank.milo" -> return TrashyKit
      "sfx/kit05_bank.milo" -> return ElectronicKit
      s -> do
        warn $ "Unrecognized drum bank " ++ show s
        return HardRockKit
  let diffMap :: HM.HashMap T.Text Config.Difficulty
      diffMap = let
        -- We assume that if every rank value is a tier boundary,
        -- it's a Magma-produced song where the author selected tiers.
        -- So we should import to tiers, not ranks.
        isTierBoundary (k, v) = case k of
          "drum"        -> (k,) <$> elemIndex v (0 : 1 : drumsDiffMap)
          "guitar"      -> (k,) <$> elemIndex v (0 : 1 : guitarDiffMap)
          "bass"        -> (k,) <$> elemIndex v (0 : 1 : bassDiffMap)
          "vocals"      -> (k,) <$> elemIndex v (0 : 1 : vocalDiffMap)
          "keys"        -> (k,) <$> elemIndex v (0 : 1 : keysDiffMap)
          "real_keys"   -> (k,) <$> elemIndex v (0 : 1 : keysDiffMap)
          "real_guitar" -> (k,) <$> elemIndex v (0 : 1 : proGuitarDiffMap)
          "real_bass"   -> (k,) <$> elemIndex v (0 : 1 : proBassDiffMap)
          "band"        -> (k,) <$> elemIndex v (0 : 1 : bandDiffMap)
          _             -> Nothing
        in case mapM isTierBoundary $ HM.toList $ D.rank pkg of
          Nothing    -> Rank                <$> D.rank pkg
          Just tiers -> Tier . fromIntegral <$> HM.fromList tiers
      hasRankStr s = maybe False (/= 0) $ HM.lookup s $ D.rank pkg
  vocalMode <- if hasRankStr "vocals"
    then case D.vocalParts $ D.song pkg of
      Nothing -> return $ Just Vocal1
      Just 0  -> return Nothing
      Just 1  -> return $ Just Vocal1
      Just 2  -> return $ Just Vocal2
      Just 3  -> return $ Just Vocal3
      n       -> fatal $ "Invalid vocal count of " ++ show n
    else return Nothing
  let hopoThresh = fromIntegral $ fromMaybe 170 $ D.hopoThreshold $ D.song pkg

  let drumEvents = RBFile.fixedPartDrums $ RBFile.s_tracks midiFixed
  (foundMix, foundMixStr) <- let
    drumMixes = do
      (_, dd) <- Map.toList $ drumDifficulties drumEvents
      (aud, _dsc) <- toList $ drumMix dd
      return aud
    in case drumMixes of
      [] -> return (Nothing, "MIDI has no mix")
      aud : auds -> if all (== aud) auds
        then return (Just aud, "MIDI has mix " <> take 1 (reverse $ show aud))
        else do
          warn $ "Inconsistent drum mixes: " ++ show (nubOrd drumMixes)
          return (Nothing, "MIDI specifies more than one mix")
  let instChans :: [(T.Text, [Int])]
      instChans = map (second $ map fromIntegral) $ D.fromDictList $ D.tracks $ D.song pkg
      drumChans = fromMaybe [] $ lookup "drum" instChans
  drumSplit <- if not (hasRankStr "drum") || level == ImportQuick then return Nothing else do
    -- Usually there should be 2-6 drum channels and a matching mix event. Seen exceptions:
    -- * The Kill (30STM) has 5 drum channels but no mix event
    -- * RB PS2 has wrong mix events leftover from 360/PS3, e.g. Can't Let Go has 4 drum channels but mix 3
    -- So, just use what the mix should be based on channel count. (But warn appropriately)
    case drumChans of
      [kitL, kitR] -> do
        when (foundMix /= Just RBDrums.D0) $ warn $ "Using drum mix 0 (2 drum channels found), " <> foundMixStr
        return $ Just $ PartSingle [kitL, kitR]
      [kick, snare, kitL, kitR] -> do
        when (foundMix /= Just RBDrums.D1) $ warn $ "Using drum mix 1 (4 drum channels found), " <> foundMixStr
        return $ Just $ PartDrumKit (Just [kick]) (Just [snare]) [kitL, kitR]
      [kick, snareL, snareR, kitL, kitR] -> do
        when (foundMix /= Just RBDrums.D2) $ warn $ "Using drum mix 2 (5 drum channels found), " <> foundMixStr
        return $ Just $ PartDrumKit (Just [kick]) (Just [snareL, snareR]) [kitL, kitR]
      [kickL, kickR, snareL, snareR, kitL, kitR] -> do
        when (foundMix /= Just RBDrums.D3) $ warn $ "Using drum mix 3 (6 drum channels found), " <> foundMixStr
        return $ Just $ PartDrumKit (Just [kickL, kickR]) (Just [snareL, snareR]) [kitL, kitR]
      [kick, kitL, kitR] -> do
        when (foundMix /= Just RBDrums.D4) $ warn $ "Using drum mix 4 (3 drum channels found), " <> foundMixStr
        return $ Just $ PartDrumKit (Just [kick]) Nothing [kitL, kitR]
      _ -> do
        warn $ "Unexpected number of drum channels (" <> show (length drumChans) <> "), importing as single-track stereo (mix 0)"
        return $ Just $ PartSingle drumChans

  let tone = fromMaybe Minor $ D.songTonality pkg
      -- Minor verified as default for PG chords if SK/VTN present and no song_tonality
      (skey, vkey) = case (D.songKey pkg, D.vocalTonicNote pkg) of
        (Just sk, Just vtn) -> (Just $ SongKey sk  tone, Just vtn)
        (Just sk, Nothing ) -> (Just $ SongKey sk  tone, Nothing )
        (Nothing, Just vtn) -> (Just $ SongKey vtn tone, Nothing )
        (Nothing, Nothing ) -> (Nothing                , Nothing )

      bassBase = detectExtProBass $ RBFile.s_tracks midiFixed

  miloFolder <- case (level, rbiMilo rbi) of
    (ImportFull, Just milo) -> errorToWarning $ do
      bs <- stackIO $ useHandle milo handleToByteString
      dec <- runGetM decompressMilo bs
      snd . miloToFolder <$> runGetM parseMiloFile dec
    _ -> return Nothing
  let flatten folder = folderFiles folder <> concatMap (flatten . snd) (folderSubfolders folder)
      flat = maybe [] flatten miloFolder
      lipsyncNames = ["song.lipsync", "part2.lipsync", "part3.lipsync", "part4.lipsync"]
      getLipsyncFile name = do
        bs <- lookup name flat
        return
          $ LipsyncFile
          $ SoftFile (B8.unpack name)
          $ SoftReadable
          $ makeHandle (B8.unpack name)
          $ byteStringSimpleHandle bs
      takeWhileJust (Just x : xs) = x : takeWhileJust xs
      takeWhileJust _             = []
  songPref <- case lookup "BandSongPref" flat of
    Nothing -> return Nothing
    Just bs -> do
      lg "Loading BandSongPref"
      errorToWarning $ runGetM (codecIn bin) bs
  let lookupPref fn defAssign = case songPref of
        Nothing -> return defAssign
        Just pref -> case fn pref of
          "guitar" -> return LipsyncGuitar
          "bass" -> return LipsyncBass
          "drum" -> return LipsyncDrums
          x -> do
            warn $ "Unrecognized lipsync part assignment: " <> show x
            return defAssign
  pref2 <- lookupPref prefPart2 LipsyncGuitar
  pref3 <- lookupPref prefPart3 LipsyncBass
  pref4 <- lookupPref prefPart4 LipsyncDrums
  -- TODO also import the animation style parameter
  let lipsync = case takeWhileJust $ map getLipsyncFile lipsyncNames of
        []   -> Nothing
        srcs -> Just $ LipsyncRB3 srcs pref2 pref3 pref4
  songAnim <- case lookup "song.anim" flat of
    Nothing -> return Nothing
    Just bs -> do
      lg "Loading song.anim"
      return $ Just $ SoftFile "song.anim" $ SoftReadable $ makeHandle "song.anim" $ byteStringSimpleHandle bs

  (video, vgs) <- case guard (level == ImportFull) >> rbiPSS rbi of
    Nothing     -> return (Nothing, Nothing)
    Just getPSS -> do
      (video, vgs) <- stackIO getPSS
      return (Just video, Just vgs)
  let namedChans = do
        (i, chan) <- zip [0..] $ fromMaybe [] vgs
        return ("vgs-" <> show (i :: Int), chan)

  return SongYaml
    { _metadata = Metadata
      { _title        = Just title
      , _titleJP      = Nothing
      , _artist       = case (D.artist pkg, D.gameOrigin pkg) of
        (Nothing, Just "beatles") -> Just "The Beatles"
        _                         -> D.artist pkg
      , _artistJP     = Nothing
      , _album        = D.albumName pkg
      , _genre        = D.genre pkg
      , _subgenre     = D.subGenre pkg >>= T.stripPrefix "subgenre_"
      , _year         = case (D.yearReleased pkg, D.gameOrigin pkg, D.dateReleased pkg) of
        (Nothing, Just "beatles", Just date) -> readMaybe $ T.unpack $ T.take 4 date
        _ -> fromIntegral <$> D.yearReleased pkg
      , _fileAlbumArt = rbiAlbumArt rbi
      , _trackNumber  = fromIntegral <$> D.albumTrackNumber pkg
      , _comments     = []
      , _difficulty   = fromMaybe (Tier 1) $ HM.lookup "band" diffMap
      , _key          = skey
      , _author       = D.author pkg <|> c3dtaAuthoredBy (rbiComments rbi)
      , _rating       = toEnum $ fromIntegral $ D.rating pkg - 1
      , _previewStart = Just $ PreviewSeconds $ fromIntegral (fst $ D.preview pkg) / 1000
      , _previewEnd   = Just $ PreviewSeconds $ fromIntegral (snd $ D.preview pkg) / 1000
      , _languages    = fromMaybe [] $ c3dtaLanguages $ rbiComments rbi
      , _convert      = fromMaybe False $ c3dtaConvert $ rbiComments rbi
      , _rhythmKeys   = fromMaybe False $ c3dtaRhythmKeys $ rbiComments rbi
      , _rhythmBass   = fromMaybe False $ c3dtaRhythmBass $ rbiComments rbi
      , _catEMH       = fromMaybe False $ c3dtaCATemh $ rbiComments rbi
      , _expertOnly   = fromMaybe False $ c3dtaExpertOnly $ rbiComments rbi
      , _cover        = not $ D.master pkg || D.gameOrigin pkg == Just "beatles"
      }
    , _global = def'
      { _animTempo           = D.animTempo pkg
      , _fileMidi            = SoftFile "notes.mid" $ SoftChart midiOnyx
      , _fileSongAnim        = songAnim
      , _backgroundVideo     = flip fmap video $ \videoFile -> VideoInfo
        { _fileVideo      = videoFile
        , _videoStartTime = Just $ rockBandPS2PreSongTime pkg
        , _videoEndTime   = Nothing
        , _videoLoop      = False
        }
      , _fileBackgroundImage = Nothing
      }
    , _audio = HM.fromList $ do
      (name, bs) <- namedChans
      return $ (T.pack name ,) $ AudioFile AudioInfo
        { _md5 = Nothing
        , _frames = Nothing
        , _commands = []
        , _filePath = Just $ SoftFile (name <.> "vgs") $ SoftReadable $ makeHandle name $ byteStringSimpleHandle bs
        , _rate = Nothing
        , _channels = 1
        }
    , _jammit = HM.empty
    , _plans = case rbiMOGG rbi of
      Nothing -> case rbiPSS rbi of
        Nothing -> HM.empty
        Just _pss -> HM.singleton "vgs" $ let
          songChans = [0 .. length namedChans - 1] \\ concat
            [ concatMap snd instChans
            , maybe [] (map fromIntegral) $ D.crowdChannels $ D.song pkg
            ]
          audioAdjust = Drop Start $ CA.Seconds $ rockBandPS2PreSongTime pkg
          mixChans cs = do
            cs' <- NE.nonEmpty cs
            Just $ case cs' of
              c :| [] -> PlanAudio
                { _planExpr = audioAdjust $ Input $ Named $ T.pack $ fst $ namedChans !! c
                , _planPans = map realToFrac [D.pans (D.song pkg) !! c]
                , _planVols = map realToFrac [D.vols (D.song pkg) !! c]
                }
              _ -> PlanAudio
                { _planExpr = audioAdjust $ Merge $ fmap (Input . Named . T.pack . fst . (namedChans !!)) cs'
                , _planPans = map realToFrac [D.pans (D.song pkg) !! c | c <- cs]
                , _planVols = map realToFrac [D.vols (D.song pkg) !! c | c <- cs]
                }
          in Plan
            { _song = mixChans songChans
            , _countin = Countin []
            , _planParts = Parts $ HM.fromList $ catMaybes
              [ lookup "guitar" instChans >>= mixChans >>= \x -> return (FlexGuitar, PartSingle x)
              , lookup "bass"   instChans >>= mixChans >>= \x -> return (FlexBass  , PartSingle x)
              , lookup "keys"   instChans >>= mixChans >>= \x -> return (FlexKeys  , PartSingle x)
              , lookup "vocals" instChans >>= mixChans >>= \x -> return (FlexVocal , PartSingle x)
              , drumSplit >>= mapM mixChans            >>= \x -> return (FlexDrums , x)
              ]
            , _crowd = D.crowdChannels (D.song pkg) >>= mixChans . map fromIntegral
            , _planComments = []
            , _tuningCents = maybe 0 round $ D.tuningOffsetCents pkg
            , _fileTempo = Nothing
            }
      Just mogg -> HM.singleton "mogg" MoggPlan
        { _fileMOGG = Just $ SoftFile "audio.mogg" mogg
        , _moggMD5 = Nothing
        , _moggParts = Parts $ HM.fromList $ concat
          [ [ (FlexGuitar, PartSingle ns) | ns <- toList $ lookup "guitar" instChans ]
          , [ (FlexBass  , PartSingle ns) | ns <- toList $ lookup "bass"   instChans ]
          , [ (FlexKeys  , PartSingle ns) | ns <- toList $ lookup "keys"   instChans ]
          , [ (FlexVocal , PartSingle ns) | ns <- toList $ lookup "vocals" instChans ]
          , [ (FlexDrums , ds           ) | Just ds <- [drumSplit] ]
          ]
        , _moggCrowd = maybe [] (map fromIntegral) $ D.crowdChannels $ D.song pkg
        , _pans = map realToFrac $ D.pans $ D.song pkg
        , _vols = map realToFrac $ D.vols $ D.song pkg
        , _planComments = []
        , _tuningCents = maybe 0 round $ D.tuningOffsetCents pkg
        , _fileTempo = Nothing
        , _karaoke = fromMaybe False $ c3dtaKaraoke $ rbiComments rbi
        , _multitrack = fromMaybe True $ c3dtaMultitrack $ rbiComments rbi
        , _decryptSilent = False
        }
    , _targets = let
      getSongID = \case
        Left  i -> if i /= 0
          then SongIDInt $ fromIntegral i
          else SongIDAutoSymbol
        Right k -> SongIDSymbol k
      songID1x = maybe SongIDAutoSymbol getSongID $ D.songId pkg
      songID2x = if hasKicks == Kicks2x
        then songID1x
        else maybe SongIDAutoSymbol getSongID $ files2x >>= D.songId . fst
      version1x = guard (songID1x /= SongIDAutoSymbol) >> Just (D.version pkg)
      version2x = guard (songID2x /= SongIDAutoSymbol) >> fmap (D.version . fst) files2x
      targetShared = def'
        { rb3_Harmonix = dtaIsHarmonixRB3 pkg
        }
      target1x = ("rb3", RB3 targetShared
        { rb3_2xBassPedal = False
        , rb3_SongID = songID1x
        , rb3_Version = version1x
        })
      target2x = ("rb3-2x", RB3 targetShared
        { rb3_2xBassPedal = True
        , rb3_SongID = songID2x
        , rb3_Version = version2x
        })
      in HM.fromList $ concat [[target1x | hasKicks /= Kicks2x], [target2x | hasKicks /= Kicks1x]]
    , _parts = Parts $ HM.fromList
      [ ( FlexDrums, def
        { partDrums = guard (hasRankStr "drum") >> Just PartDrums
          { drumsDifficulty = fromMaybe (Tier 1) $ HM.lookup "drum" diffMap
          , drumsMode = DrumsPro
          , drumsKicks = hasKicks
          , drumsFixFreeform = False
          , drumsKit = drumkit
          , drumsLayout = StandardLayout -- TODO import this
          , drumsFallback = FallbackGreen
          , drumsFileDTXKit = Nothing
          , drumsFullLayout = FDStandard
          }
        })
      , ( FlexGuitar, def
        { partGRYBO = guard (hasRankStr "guitar") >> Just PartGRYBO
          { gryboDifficulty = fromMaybe (Tier 1) $ HM.lookup "guitar" diffMap
          , gryboHopoThreshold = hopoThresh
          , gryboFixFreeform = False
          , gryboSmoothFrets = False
          , gryboSustainGap = 60
          }
        , partProGuitar = guard (hasRankStr "real_guitar") >> Just PartProGuitar
          { pgDifficulty = fromMaybe (Tier 1) $ HM.lookup "real_guitar" diffMap
          , pgHopoThreshold = hopoThresh
          , pgTuning = GtrTuning
            { gtrBase = Guitar6
            , gtrOffsets = map fromIntegral $ fromMaybe [] $ D.realGuitarTuning pkg
            , gtrGlobal = 0
            , gtrCapo = 0
            }
          , pgTuningRSBass  = Nothing
          , pgFixFreeform   = False
          , pgTones         = Nothing
          , pgPickedBass    = False
          }
        })
      , ( FlexBass, def
        { partGRYBO = guard (hasRankStr "bass") >> Just PartGRYBO
          { gryboDifficulty = fromMaybe (Tier 1) $ HM.lookup "bass" diffMap
          , gryboHopoThreshold = hopoThresh
          , gryboFixFreeform = False
          , gryboSmoothFrets = False
          , gryboSustainGap = 60
          }
        , partProGuitar = guard (hasRankStr "real_bass") >> Just PartProGuitar
          { pgDifficulty = fromMaybe (Tier 1) $ HM.lookup "real_bass" diffMap
          , pgHopoThreshold = hopoThresh
          , pgTuning = GtrTuning
            { gtrBase = bassBase
            , gtrOffsets = map fromIntegral $ fromMaybe [] $ D.realBassTuning pkg
            , gtrGlobal = 0
            , gtrCapo = 0
            }
          , pgTuningRSBass  = Nothing
          , pgFixFreeform   = False
          , pgTones         = Nothing
          , pgPickedBass    = False
          }
        })
      , ( FlexKeys, def
        { partGRYBO = guard (hasRankStr "keys") >> Just PartGRYBO
          { gryboDifficulty = fromMaybe (Tier 1) $ HM.lookup "keys" diffMap
          , gryboHopoThreshold = hopoThresh
          , gryboFixFreeform = False
          , gryboSmoothFrets = False
          , gryboSustainGap = 60
          }
        , partProKeys = guard (hasRankStr "real_keys") >> Just PartProKeys
          { pkDifficulty = fromMaybe (Tier 1) $ HM.lookup "real_keys" diffMap
          , pkFixFreeform = False
          }
        })
      , ( FlexVocal, def
        { partVocal = flip fmap vocalMode $ \vc -> PartVocal
          { vocalDifficulty = fromMaybe (Tier 1) $ HM.lookup "vocals" diffMap
          , vocalCount = vc
          , vocalGender = D.vocalGender pkg
          , vocalKey = vkey
          , vocalLipsyncRB3 = lipsync
          }
        })
      ]
    }

importRB4 :: (SendMessage m, MonadIO m) => FilePath -> Import m
importRB4 fdta level = do
  dta <- stackIO (BL.fromStrict <$> B.readFile fdta) >>= runGetM (codecIn bin)

  moggDTA <- stackIO (D.readFileDTA $ fdta -<.> "mogg.dta") >>= D.unserialize D.stackChunks

  (midRead, hopoThreshold) <- case level of
    ImportQuick -> return (makeHandle "notes.mid" $ byteStringSimpleHandle BL.empty, 170)
    ImportFull  -> do
      rbmid <- stackIO (BL.fromStrict <$> B.readFile (fdta -<.> "rbmid_ps4")) >>= runGetM (codecIn bin)
      mid <- extractMidi rbmid
      return (makeHandle "notes.mid" $ byteStringSimpleHandle $ Save.toByteString mid, rbmid_HopoThreshold rbmid)

  -- sdta_AlbumArt doesn't appear to be correct, it is False sometimes when song should have art
  art <- if level == ImportFull
    then errorToWarning $ do
      img <- stackIO (BL.fromStrict <$> B.readFile (fdta -<.> "png_ps4")) >>= runGetM readPNGPS4
      return $ SoftFile "cover.png" $ SoftImage $ pixelMap dropTransparency img
    else return Nothing

  let decodeBS = TE.decodeUtf8 -- is this correct? find example with non-ascii char
      pkg = D.SongPackage
        { D.name              = decodeBS $ sdta_Name dta
        , D.artist            = Just $ decodeBS $ sdta_Artist dta
        , D.master            = not $ sdta_Cover dta
        , D.song              = D.Song
          { D.songName         = decodeBS $ sdta_Shortname dta
          , D.tracksCount      = Nothing
          -- should be fine to keep 'fake' in tracks list, ignore later
          , D.tracks           = D.DictList
            -- need to merge the duplicate drum keys (see below)
            $ Map.toList
            $ Map.unionsWith (<>)
            $ map (uncurry Map.singleton)
            $ rb4_tracks moggDTA
          , D.pans             = rb4_pans moggDTA
          , D.vols             = rb4_vols moggDTA
          , D.cores            = map (const (-1)) $ rb4_pans moggDTA
          , D.crowdChannels    = Nothing -- TODO
          , D.vocalParts       = Just $ fromIntegral $ sdta_VocalParts dta
          , D.drumSolo         = D.DrumSounds [] -- not used
          , D.drumFreestyle    = D.DrumSounds [] -- not used
          , D.muteVolume       = Nothing -- not used
          , D.muteVolumeVocals = Nothing -- not used
          , D.hopoThreshold    = Just $ fromIntegral hopoThreshold
          , D.midiFile         = Nothing
          }
        , D.songScrollSpeed   = 2300
        , D.bank              = Nothing
        , D.drumBank          = Nothing
        , D.animTempo         = case sdta_AnimTempo dta of
          "medium" -> Left D.KTempoMedium
          -- TODO
          _        -> Left D.KTempoMedium
        , D.songLength        = Just $ round $ sdta_SongLength dta
        , D.preview           = (round $ sdta_PreviewStart dta, round $ sdta_PreviewEnd dta)
        , D.rank              = HM.fromList
          [ ("drum"       , round $ sdta_DrumRank     dta)
          , ("bass"       , round $ sdta_BassRank     dta)
          , ("guitar"     , round $ sdta_GuitarRank   dta)
          , ("vocals"     , round $ sdta_VocalsRank   dta)
          , ("keys"       , round $ sdta_KeysRank     dta)
          , ("real_keys"  , round $ sdta_RealKeysRank dta)
          , ("band"       , round $ sdta_BandRank     dta)
          ]
        , D.genre             = Just $ decodeBS $ sdta_Genre dta
        , D.vocalGender       = case sdta_VocalGender dta of
          1 -> Just Male
          2 -> Just Female
          _ -> Nothing
        , D.version           = fromIntegral $ sdta_Version dta
        , D.songFormat        = 10 -- we'll call it rb3 format for now
        , D.albumArt          = Just $ isJust art
        , D.yearReleased      = Just $ fromIntegral $ sdta_AlbumYear dta
        , D.rating            = 4 -- TODO
        , D.subGenre          = Nothing
        , D.songId            = Just $ Left $ fromIntegral $ sdta_SongId dta
        , D.solo              = Nothing
        , D.tuningOffsetCents = Nothing -- TODO
        , D.guidePitchVolume  = Nothing
        , D.gameOrigin        = Just $ decodeBS $ sdta_GameOrigin dta
        , D.encoding          = Just "utf8" -- dunno
        , D.albumName         = Just $ decodeBS $ sdta_AlbumName dta -- can this be blank?
        , D.albumTrackNumber  = Just $ fromIntegral $ sdta_AlbumTrackNumber dta
        , D.vocalTonicNote    = Nothing -- TODO
        , D.songTonality      = Nothing -- TODO
        , D.realGuitarTuning  = Nothing
        , D.realBassTuning    = Nothing
        , D.bandFailCue       = Nothing
        , D.fake              = Just $ sdta_Fake dta
        , D.ugc               = Nothing
        , D.shortVersion      = Nothing
        , D.yearRecorded      = guard (sdta_OriginalYear dta /= sdta_AlbumYear dta) >> Just (fromIntegral $ sdta_OriginalYear dta)
        , D.packName          = Nothing
        , D.songKey           = Nothing
        , D.extraAuthoring    = Nothing
        , D.context           = Nothing
        , D.decade            = Nothing
        , D.downloaded        = Nothing
        , D.basePoints        = Nothing
        , D.alternatePath     = Nothing
        , D.videoVenues       = Nothing
        , D.dateReleased      = Nothing
        , D.dateRecorded      = Nothing
        , D.author            = Nothing
        , D.video             = False
        }

  importRB RBImport
    { rbiSongPackage = pkg
    , rbiComments = def
    , rbiMOGG = Just $ SoftReadable $ fileReadable $ fdta -<.> "mogg"
    , rbiPSS = Nothing
    , rbiAlbumArt = art
    , rbiMilo = Nothing
    , rbiMIDI = midRead
    , rbiMIDIUpdate = Nothing
    , rbiSource = Nothing
    } level

{-

note: unlike pre-rb4, the tracks list has duplicate keys if there's more than 1 drum stream:

  (drum
     (0)
  )
  (drum
     (1 2)
  )
  (drum
     (3 4)
  )

-}

data RB4MoggDta = RB4MoggDta
  { rb4_tracks :: [(T.Text, [Integer])]
  , rb4_pans   :: [Float]
  , rb4_vols   :: [Float]
  } deriving (Eq, Show)

instance D.StackChunks RB4MoggDta where
  stackChunks = D.asWarnAssoc "RB4MoggDta" $ do
    rb4_tracks <- rb4_tracks =. req "tracks" (D.chunksParens $ D.chunksList $ D.chunkParens $ D.chunksKeyRest D.chunkSym D.channelList)
    rb4_pans   <- rb4_pans   =. req "pans"   (D.chunksParens D.stackChunks)
    rb4_vols   <- rb4_vols   =. req "vols"   (D.chunksParens D.stackChunks)
    return RB4MoggDta{..}
