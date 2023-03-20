-- Extracting and converting parts between different gameplay modes
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE NoFieldSelectors      #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PatternSynonyms       #-}
{-# LANGUAGE StrictData            #-}
{-# LANGUAGE TupleSections         #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}
module Onyx.Mode where

import           Control.Applicative              ((<|>))
import           Control.Monad                    (guard)
import           Data.Bifunctor                   (first, second)
import           Data.Default.Class               (def)
import qualified Data.EventList.Absolute.TimeBody as ATB
import qualified Data.EventList.Relative.TimeBody as RTB
import           Data.Foldable                    (find)
import           Data.Functor                     (void)
import           Data.List.Extra                  (nubOrd, sort)
import qualified Data.Map                         as Map
import           Data.Maybe                       (catMaybes, fromMaybe, isJust,
                                                   listToMaybe)
import qualified Data.Text                        as T
import           Onyx.AutoChart                   (autoChart)
import           Onyx.Drums.OneFoot               (phaseShiftKicks, rockBand1x,
                                                   rockBand2x)
import           Onyx.Guitar
import           Onyx.MIDI.Common                 (StrumHOPOTap (..),
                                                   pattern RNil, pattern Wait)
import qualified Onyx.MIDI.Common                 as RB
import           Onyx.MIDI.Read                   (mapTrack)
import qualified Onyx.MIDI.Track.Drums            as D
import qualified Onyx.MIDI.Track.Drums.Full       as FD
import           Onyx.MIDI.Track.Events
import qualified Onyx.MIDI.Track.File             as F
import qualified Onyx.MIDI.Track.FiveFret         as Five
import           Onyx.MIDI.Track.Mania
import           Onyx.MIDI.Track.ProGuitar        (getStringIndex,
                                                   tuningPitches)
import           Onyx.MIDI.Track.ProKeys
import           Onyx.MIDI.Track.Rocksmith
import           Onyx.PhaseShift.Dance
import           Onyx.Project
import qualified Sound.MIDI.Util                  as U

data ModeInput = ModeInput
  { tempo  :: U.TempoMap
  , events :: EventsTrack U.Beats
  , part   :: F.OnyxPart U.Beats
  }

------------------------------------------------------------------

data FiveResult = FiveResult
  { settings  :: PartGRYBO
  , notes     :: Map.Map RB.Difficulty (RTB.T U.Beats ((Maybe Five.Color, StrumHOPOTap), Maybe U.Beats))
  , other     :: Five.FiveTrack U.Beats
  , source    :: T.Text
  , autochart :: Bool
  }

data FiveType
  = FiveTypeGuitar    -- prefer no extended sustains + no open notes
  | FiveTypeKeys      -- prefer    extended sustains + no open notes
  | FiveTypeGuitarExt -- prefex    extended sustains +    open notes
  deriving (Eq, Show)

type BuildFive = FiveType -> ModeInput -> FiveResult

nativeFiveFret :: Part f -> Maybe BuildFive
nativeFiveFret part = flip fmap part.grybo $ \grybo ftype input -> let
  gtr  = (F.onyxPartGuitar    input.part, HOPOsRBGuitar)
  keys = (F.onyxPartKeys      input.part, HOPOsRBKeys  )
  ext  = (F.onyxPartGuitarExt input.part, HOPOsRBGuitar)
  trks = case ftype of
    FiveTypeGuitar    -> [gtr, ext, keys]
    FiveTypeKeys      -> [keys, ext, gtr] -- prefer ext due to sustains? or gtr due to no opens? dunno
    FiveTypeGuitarExt -> [ext, gtr, keys]
  -- TODO maybe fill in lower difficulties from secondary tracks
  (trk, algo) = fromMaybe (mempty, HOPOsRBGuitar) $ find (not . Five.nullFive . fst) trks
  in FiveResult
    { settings  = grybo
    , notes     = flip fmap (Five.fiveDifficulties trk) $ \diff ->
      applyForces (getForces5 diff)
        $ strumHOPOTap algo (fromIntegral grybo.hopoThreshold / 480)
        $ computeFiveFretNotes diff
    , other     = trk
    , source    = "five-fret chart"
    , autochart = False
    }

anyFiveFret :: Part f -> Maybe BuildFive
anyFiveFret p
  = nativeFiveFret p
  <|> proGuitarToFiveFret p
  <|> proKeysToFiveFret p
  <|> maniaToFiveFret p
  <|> danceToFiveFret p
  <|> fmap convertDrumsToFive (nativeDrums p)

convertDrumsToFive :: BuildDrums -> BuildFive
convertDrumsToFive bd _ftype input = let
  drumResult = bd DrumTargetRB2x input
  in FiveResult
    { settings = (def :: PartGRYBO)
      { difficulty = drumResult.settings.difficulty
      }
    , notes = flip fmap drumResult.notes $ \drumGems ->
      strumHOPOTap HOPOsRBGuitar (170/480) $ flip fmap drumGems $ \(gem, _velocity) -> let
        color = case gem of
          D.Kick           -> Five.Green
          D.Red            -> Five.Red
          D.Pro D.Yellow _ -> Five.Yellow
          D.Pro D.Blue   _ -> Five.Blue
          D.Pro D.Green  _ -> Five.Orange
          D.Orange         -> Five.Orange -- won't happen because we called buildDrums with RB3 target
        in (Just color, Nothing)
    , other = Five.FiveTrack
      { Five.fiveDifficulties = Map.empty
      , Five.fiveMood         = D.drumMood drumResult.other
      , Five.fiveHandMap      = RTB.empty
      , Five.fiveStrumMap     = RTB.empty
      , Five.fiveFretPosition = RTB.empty
      , Five.fiveTremolo      = RTB.empty -- TODO include these sometimes?
      , Five.fiveTrill        = RTB.empty -- TODO include these sometimes?
      , Five.fiveOverdrive    = D.drumOverdrive drumResult.other
      , Five.fiveBRE          = let
        -- only copy over a fill that is actually a BRE
        coda = fmap (fst . fst) $ RTB.viewL $ eventsCoda input.events
        in case coda of
          Nothing -> RTB.empty
          Just c  -> RTB.delay c $ U.trackDrop c $ D.drumActivation drumResult.other
      , Five.fiveSolo         = D.drumSolo drumResult.other
      , Five.fivePlayer1      = D.drumPlayer1 drumResult.other
      , Five.fivePlayer2      = D.drumPlayer2 drumResult.other
      }
    , source = "converted drum chart to five-fret"
    , autochart = False
    }

------------------------------------------------------------------

data DrumResult = DrumResult
  { settings   :: PartDrums ()
  , notes      :: Map.Map RB.Difficulty (RTB.T U.Beats (D.Gem D.ProType, D.DrumVelocity))
  , other      :: D.DrumTrack U.Beats -- includes 2x kicks when CH/GH format is requested
  , animations :: RTB.T U.Beats D.Animation
  , hasRBMarks :: Bool -- True if `other` includes correct tom markers and mix events
  , source     :: T.Text
  , autochart  :: Bool
  }

data DrumTarget
  = DrumTargetRB1x -- pro, 1x
  | DrumTargetRB2x -- pro, 2x
  | DrumTargetCH -- pro, x+
  | DrumTargetGH -- 5-lane, x+

type BuildDrums = DrumTarget -> ModeInput -> DrumResult

nativeDrums :: Part f -> Maybe BuildDrums
nativeDrums part = flip fmap part.drums $ \pd dtarget input -> let

  src1x   =                             F.onyxPartDrums       input.part
  src2x   =                             F.onyxPartDrums2x     input.part
  srcReal = D.psRealToPro             $ F.onyxPartRealDrumsPS input.part
  srcFull = FD.convertFullDrums False $ F.onyxPartFullDrums   input.part
  srcsRB = case dtarget of
    DrumTargetRB1x -> [src1x, src2x]
    _              -> [src2x, src1x]
  srcList = case pd.mode of
    DrumsReal -> srcReal : srcsRB
    DrumsFull -> srcFull : srcsRB
    _         -> srcsRB
  src = fromMaybe mempty $ find (not . D.nullDrums) srcList

  stepAddKicks = case pd.kicks of
    Kicks2x -> mapTrack (U.unapplyTempoTrack input.tempo) . phaseShiftKicks 0.18 0.11 . mapTrack (U.applyTempoTrack input.tempo)
    _       -> id

  isRBTarget = case dtarget of
    DrumTargetRB1x -> True
    DrumTargetRB2x -> True
    _              -> False

  stepRBKicks = case dtarget of
    DrumTargetRB1x -> rockBand1x
    DrumTargetRB2x -> rockBand2x
    _              -> id

  drumEachDiff f dt = dt { D.drumDifficulties = fmap f $ D.drumDifficulties dt }
  step5to4 = if pd.mode == Drums5 && isRBTarget
    then drumEachDiff $ \dd -> dd
      { D.drumGems = D.fiveToFour
        (case pd.fallback of
          FallbackBlue  -> D.Blue
          FallbackGreen -> D.Green
        )
        (D.drumGems dd)
      }
    else id

  isBasicSource = case pd.mode of
    Drums4 -> True
    Drums5 -> True
    _      -> False

  src'
    = (if pd.fixFreeform then F.fixFreeformDrums else id)
    $ step5to4 $ stepRBKicks $ stepAddKicks src

  modifyProType ptype = if isBasicSource
    then if isRBTarget then D.Tom else D.Cymbal
    else ptype

  -- TODO pro to 5 conversion (for GH target)
  -- Move logic from Neversoft.Export to here

  in DrumResult
    { settings = void pd
    , notes = Map.fromList $ do
      diff <- [minBound .. maxBound]
      let gems = first (fmap modifyProType) <$> D.computePro (Just diff) src'
      guard $ not $ RTB.null gems
      return (diff, gems)
    , other = src'
    , animations = buildDrumAnimation pd input.tempo input.part
    , hasRBMarks = not isBasicSource
    , source = "drum chart"
    , autochart = False
    }

anyDrums :: Part f -> Maybe BuildDrums
anyDrums p
  = nativeDrums p
  <|> maniaToDrums p
  <|> danceToDrums p

buildDrumAnimation
  :: PartDrums f
  -> U.TempoMap
  -> F.OnyxPart U.Beats
  -> RTB.T U.Beats D.Animation
buildDrumAnimation pd tmap opart = let
  rbTracks = map ($ opart) [F.onyxPartRealDrumsPS, F.onyxPartDrums2x, F.onyxPartDrums]
  inRealTime f = U.unapplyTempoTrack tmap . f . U.applyTempoTrack tmap
  closeTime = 0.25 :: U.Seconds
  in case filter (not . RTB.null) $ map D.drumAnimation rbTracks of
    anims : _ -> anims
    []        -> case pd.mode of
      DrumsFull -> inRealTime (FD.autoFDAnimation closeTime)
        $ FD.getDifficulty (Just RB.Expert) $ F.onyxPartFullDrums opart
      -- TODO this could be made better for modes other than pro
      _ -> inRealTime (D.autoDrumAnimation closeTime)
        $ fmap fst $ D.computePro (Just RB.Expert)
        $ case filter (not . D.nullDrums) rbTracks of
          trk : _ -> trk
          []      -> mempty

------------------------------------------------------------------

simplifyChord :: [Int] -> [Int]
simplifyChord pitches = case pitches of
  [_]    -> pitches
  [_, _] -> pitches
  _      -> let
    sorted = sort pitches
    keys = nubOrd $ map (`rem` 12) pitches
    in if length keys <= 2
      then take 2 sorted -- power chords or octaves become max 2-note
      else take 3 sorted -- otherwise max 3-note
      -- maybe have a smarter way of thinning? (preserve unique keys)

-- For more GHRB-like style, turns some strums into hopos, and some hopos into taps
adjustRocksmithHST
  :: U.TempoMap
  -> RTB.T U.Beats [((Maybe Five.Color, StrumHOPOTap), Maybe U.Beats)]
  -> RTB.T U.Beats [((Maybe Five.Color, StrumHOPOTap), Maybe U.Beats)]
adjustRocksmithHST tempos = let
  timeLong, timeShort :: U.Seconds
  timeLong  = 0.5
  timeShort = 0.13 -- may want to adjust this, could be too high for some situations
  go = \case
    -- tap, hopo: hopo should become tap
    Wait t1 chord1@(((_, Tap), _) : _) (Wait t2 chord2@(((_, HOPO), _) : _) rest)
      ->  Wait t1 chord1
        $ go
        $ Wait t2 [ ((color, Tap), len) | ((color, _), len) <- chord2 ] rest
    -- long gap, hopo, tap: hopo should become tap
    -- TODO support more than 1 hopo before tap
    Wait t1 chord1@(((_, HOPO), _) : _) rest@(Wait _ (((_, Tap), _) : _) _)
      | t1 >= timeLong
      ->  Wait t1 [ ((color, Tap), len) | ((color, _), len) <- chord1 ]
        $ go rest
    -- strum/hopo, short gap, strum: second note should become hopo under certain conditions
    Wait t1 note1@[((color1, sht1), _)] (Wait t2 [((color2, Strum), len2)] rest)
      |    t2 <= timeShort -- short gap between notes
        && color1 /= color2 -- different single gems
        && sht1 /= Tap -- first note is strum or hopo
        && isJust color2 -- second note isn't an open note (was fret-hand-mute in RS)
      ->  Wait t1 note1
        $ go
        $ Wait t2 [((color2, HOPO), len2)] rest
    -- otherwise nothing to change
    Wait t x rest -> Wait t x $ go rest
    RNil -> RNil
  in U.unapplyTempoTrack tempos . go . U.applyTempoTrack tempos

proGuitarToFiveFret :: Part f -> Maybe BuildFive
proGuitarToFiveFret part = flip fmap part.proGuitar $ \ppg _ftype input -> let
  in FiveResult
    { settings = (def :: PartGRYBO)
      { difficulty = ppg.difficulty
      }
    , notes = let
      -- TODO
      -- * maybe split bent notes into multiple
      chorded = RTB.toAbsoluteEventList 0 $ notesWithHandshapes $ fromMaybe (RSRockBandOutput RTB.empty RTB.empty) $ listToMaybe $ catMaybes
        [ do
          guard $ not $ RTB.null $ rsNotes $ F.onyxPartRSGuitar input.part
          return $ rsToRockBand input.tempo $ F.onyxPartRSGuitar input.part
        , do
          guard $ not $ RTB.null $ rsNotes $ F.onyxPartRSBass input.part
          return $ rsToRockBand input.tempo $ F.onyxPartRSBass input.part
        -- TODO support RB protar tracks
        ]
      strings = tuningPitches ppg.tuning
      toPitch str fret = (strings !! getStringIndex 6 str) + fret
      autoResult = autoChart 5 $ do
        (bts, (notes, _len, _shape)) <- ATB.toPairList chorded
        pitch <- simplifyChord $ nubOrd
          -- Don't give fret-hand-mute notes to the autochart,
          -- then below they will automatically become open notes
          [ toPitch str fret | (str, fret, mods) <- notes, notElem ModMute mods ]
        return (realToFrac bts, pitch)
      autoMap = foldr (Map.unionWith (<>)) Map.empty $ map
        (\(pos, fret) -> Map.singleton (realToFrac pos) [fret])
        autoResult
      in Map.singleton RB.Expert
        $ RTB.flatten
        $ adjustRocksmithHST input.tempo
        $ RTB.fromAbsoluteEventList
        $ ATB.fromPairList
        $ map (\(posn, (chord, len, _shape)) -> let
          allMods = chord >>= \(_, _, mods) -> mods
          hst = if elem ModHammerOn allMods || elem ModPullOff allMods
            then HOPO
            else if elem ModTap allMods
              then Tap
              else Strum
          notes = do
            fret <- maybe [Nothing] (map (Just . toEnum)) $ Map.lookup posn autoMap
            return ((fret, hst), len)
          in (posn, notes)
          )
        $ ATB.toPairList
        $ chorded
    , other = mempty -- TODO when RB pro tracks are supported, add overdrive, solos, etc.
    , source = "converted Rocksmith chart to five-fret"
    , autochart = True
    }

proKeysToFiveFret :: Part f -> Maybe BuildFive
proKeysToFiveFret part = flip fmap part.proKeys $ \ppk _ftype input -> let
  in FiveResult
    { settings = (def :: PartGRYBO)
      { difficulty = ppk.difficulty
      }
    , notes = let
      chorded
        = RTB.toAbsoluteEventList 0
        $ guitarify'
        $ fmap (\((), key, len) -> (fromEnum key, guard (len >= standardBlipThreshold) >> Just len))
        $ RB.joinEdgesSimple $ pkNotes $ F.onyxPartRealKeysX input.part
      autoResult = autoChart 5 $ do
        (bts, (notes, _len)) <- ATB.toPairList chorded
        pitch <- simplifyChord notes
        return (realToFrac bts, pitch)
      autoMap = foldr (Map.unionWith (<>)) Map.empty $ map
        (\(pos, fret) -> Map.singleton (realToFrac pos) [fret])
        autoResult
      in Map.singleton RB.Expert
        $ RTB.flatten
        $ RTB.fromAbsoluteEventList
        $ ATB.fromPairList
        $ map (\(posn, (_, len)) -> let
          notes = do
            fret <- maybe [Just Five.Green] (map (Just . toEnum)) $ Map.lookup posn autoMap
            return ((fret, Tap), len)
          in (posn, notes)
          )
        $ ATB.toPairList
        $ chorded
    , other = mempty -- TODO overdrive, solos, etc.
    , source = "converted Pro Keys chart to five-fret"
    , autochart = True
    }

maniaToFiveFret :: Part f -> Maybe BuildFive
maniaToFiveFret part = flip fmap part.mania $ \pm _ftype input -> let
  in FiveResult
    { settings = def :: PartGRYBO
    , notes = Map.singleton RB.Expert $ if pm.keys <= 5
      then fmap (\(k, len) -> ((Just $ toEnum k, Tap), len))
        $ RB.edgeBlips_ RB.minSustainLengthRB
        $ maniaNotes $ F.onyxPartMania input.part
        -- TODO maybe offset if less than 4 keys? like RYB for 3-key
      else let
        chorded
          = RTB.toAbsoluteEventList 0
          $ guitarify'
          $ fmap (\((), key, len) -> (key, guard (len >= standardBlipThreshold) >> Just len))
          $ RB.joinEdgesSimple $ maniaNotes $ F.onyxPartMania input.part
        autoResult = autoChart 5 $ do
          (bts, (notes, _len)) <- ATB.toPairList chorded
          pitch <- simplifyChord notes
          return (realToFrac bts, pitch)
        autoMap = foldr (Map.unionWith (<>)) Map.empty $ map
          (\(pos, fret) -> Map.singleton (realToFrac pos) [fret])
          autoResult
        in RTB.flatten
          $ RTB.fromAbsoluteEventList
          $ ATB.fromPairList
          $ map (\(posn, (_, len)) -> let
            notes = do
              fret <- maybe [Just Five.Green] (map (Just . toEnum)) $ Map.lookup posn autoMap
              return ((fret, Tap), len)
            in (posn, notes)
            )
          $ ATB.toPairList
          $ chorded
    , other = mempty
    , source = "converted Mania chart to five-fret"
    , autochart = pm.keys > 5
    }

danceToFiveFret :: Part f -> Maybe BuildFive
danceToFiveFret part = flip fmap part.dance $ \pd _ftype input -> FiveResult
  { settings = def
    { difficulty = pd.difficulty
    }
  , notes = Map.fromList $ do
    (diff, dd) <- zip [RB.Expert, RB.Hard, RB.Medium, RB.Easy] $ getDanceDifficulties $ F.onyxPartDance input.part
    let five :: RTB.T U.Beats ((Maybe Five.Color, StrumHOPOTap), Maybe U.Beats)
        five
          = RTB.mapMaybe (\case
            ((_    , NoteMine), _  ) -> Nothing
            ((arrow, _       ), len) -> Just
              ((Just $ toEnum $ fromEnum arrow, Tap), len)
            -- this turns rolls into sustains, probably fine but may want to revisit
            )
          $ RB.edgeBlips_ RB.minSustainLengthRB $ danceNotes dd
    return (diff, five)
  , other = mempty
    { Five.fiveOverdrive = danceOverdrive $ F.onyxPartDance input.part
    }
  , source = "converted dance chart to five-fret"
  , autochart = False
  }

danceToDrums :: Part f -> Maybe BuildDrums
danceToDrums part = flip fmap part.dance $ \pd dtarget input -> let
  notes :: [(RB.Difficulty, RTB.T U.Beats (D.Gem D.ProType))]
  notes = do
    (diff, dd) <- zip [RB.Expert, RB.Hard, RB.Medium, RB.Easy] $ getDanceDifficulties $ F.onyxPartDance input.part
    let diffNotes
          = RTB.flatten
          $ fmap (\xs -> case xs of
            -- max 2 notes at a time
            _ : _ : _ : _ -> [minimum xs, maximum xs]
            _             -> xs
            )
          $ RTB.collectCoincident
          $ RTB.mapMaybe (\case
            RB.EdgeOn _ (arrow, typ) | typ /= NoteMine -> Just $ case arrow of
              ArrowL -> D.Red
              ArrowD -> D.Pro D.Yellow D.Tom
              ArrowU -> D.Pro D.Blue   D.Tom
              ArrowR -> D.Pro D.Green  D.Tom
            _                                          -> Nothing
            )
          $ danceNotes dd
    return (diff, diffNotes)
  in DrumResult
    { settings = PartDrums
      { difficulty  = pd.difficulty
      , mode        = case dtarget of
        DrumTargetGH -> Drums5
        _            -> Drums4
      , kicks       = Kicks1x
      , fixFreeform = True
      , kit         = HardRockKit
      , layout      = StandardLayout
      , fallback    = FallbackGreen
      , fileDTXKit  = Nothing
      , fullLayout  = FDStandard
      }
    , notes = Map.fromList $ map (second $ fmap (, D.VelocityNormal)) notes
    , other = mempty
    , hasRBMarks = False
    , animations
      = U.unapplyTempoTrack input.tempo
      $ D.autoDrumAnimation 0.25
      $ U.applyTempoTrack input.tempo
      $ fromMaybe RTB.empty $ lookup RB.Expert notes
      :: RTB.T U.Beats D.Animation
    , source = "converted dance chart to drums"
    , autochart = False
    }

maniaToDrums :: Part f -> Maybe BuildDrums
maniaToDrums part = flip fmap part.mania $ \pm dtarget input -> let
  inputNotes :: RTB.T U.Beats Int
  inputNotes
    = RTB.flatten
    $ fmap (\xs -> case xs of
      -- max 2 notes at a time
      _ : _ : _ : _ -> [minimum xs, maximum xs]
      _             -> xs
      )
    $ RTB.collectCoincident
    $ RTB.mapMaybe (\case RB.EdgeOn _ n -> Just n; RB.EdgeOff _ -> Nothing)
    $ maniaNotes $ F.onyxPartMania input.part
  notes :: RTB.T U.Beats (D.Gem D.ProType)
  notes = if pm.keys <= laneCount
    then keyToDrum <$> inputNotes
    else RTB.fromAbsoluteEventList $ ATB.fromPairList
      $ map (\(t, n) -> (realToFrac t, keyToDrum n))
      $ autoChart laneCount
      $ map (first realToFrac) $ ATB.toPairList $ RTB.toAbsoluteEventList 0 inputNotes
  laneCount = case dtarget of
    DrumTargetGH -> 5
    _            -> 4
  -- TODO maybe put turntable lane on kick?
  keyToDrum :: Int -> D.Gem D.ProType
  keyToDrum n = case dtarget of
    DrumTargetGH -> [D.Red, D.Pro D.Yellow D.Tom, D.Pro D.Blue D.Tom, D.Orange, D.Pro D.Green D.Tom] !! n
    _            -> [D.Red, D.Pro D.Yellow D.Tom, D.Pro D.Blue D.Tom,           D.Pro D.Green D.Tom] !! n
  in DrumResult
    { settings = PartDrums
      { difficulty  = Tier 1
      , mode        = case dtarget of
        DrumTargetGH -> Drums5
        _            -> Drums4
      , kicks       = Kicks1x
      , fixFreeform = True
      , kit         = HardRockKit
      , layout      = StandardLayout
      , fallback    = FallbackGreen
      , fileDTXKit  = Nothing
      , fullLayout  = FDStandard
      }
    , notes = Map.singleton RB.Expert $ (, D.VelocityNormal) <$> notes
    , other = mempty
    , hasRBMarks = False
    , animations
      = U.unapplyTempoTrack input.tempo
      $ D.autoDrumAnimation 0.25
      $ U.applyTempoTrack input.tempo notes
      :: RTB.T U.Beats D.Animation
    , source = "converted Mania chart to drums"
    , autochart = pm.keys > laneCount
    }

drumResultToTrack :: DrumResult -> D.DrumTrack U.Beats
drumResultToTrack dr = if dr.hasRBMarks
  then dr.other
    { D.drumAnimation = dr.animations
    }
  else dr.other
    { D.drumDifficulties = flip fmap dr.notes $ \notes -> D.DrumDifficulty
      -- TODO we still need to apply discobeat! flip gems + include mix events
      { D.drumGems = first void <$> notes
      , D.drumMix = RTB.empty
      , D.drumPSModifiers = RTB.empty
      }
    , D.drumToms = let
      makeColorTomMarkers :: RTB.T U.Beats D.ProType -> RTB.T U.Beats D.ProType
      makeColorTomMarkers
        = RTB.mapMaybe (\case
          (True , D.Tom) -> Just D.Tom
          (False, D.Tom) -> Just D.Cymbal
          _              -> Nothing
          )
        . cleanEdges
        . U.trackJoin
        . fmap (\typ -> RTB.fromPairList [(0, (True, typ)), (1/480, (False, typ))])
      getColorDiff ybg = RTB.mapMaybe $ \case
        (D.Pro ybg' typ, _) | ybg == ybg' -> Just typ
        _                                 -> Nothing
      getColor ybg = let
        allDiffs = foldr RTB.merge RTB.empty $ map (getColorDiff ybg) $ Map.elems dr.notes
        getUniform = \case
          x : xs -> guard (all (== x) xs) >> Just x
          []     -> Nothing -- shouldn't happen (collectCoincident)
        in case mapM getUniform $ RTB.collectCoincident allDiffs of
          Just noConflicts -> noConflicts
          Nothing          -> getColorDiff ybg $ fromMaybe RTB.empty $ Map.lookup RB.Expert dr.notes
      in foldr RTB.merge RTB.empty $ do
        ybg <- [D.Yellow, D.Blue, D.Green]
        return $ fmap (ybg,) $ makeColorTomMarkers $ getColor ybg
    , D.drumAnimation = dr.animations
    }
