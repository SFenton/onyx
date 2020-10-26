{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia        #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE TupleSections      #-}
module Rocksmith.MIDI
( RocksmithTrack(..)
, ToneLetter(..)
, RSModifier(..)
, buildRS
, RSOutput(..)
, ChordInfo(..)
, ChordLocation(..)
, buildRSVocals
, backportAnchors
) where

import           Control.Applicative              (liftA2, (<|>))
import           Control.Monad                    (forM, guard, when)
import           Control.Monad.Codec
import           Control.Monad.Trans.StackTrace
import           Data.Char                        (isDigit)
import qualified Data.EventList.Absolute.TimeBody as ATB
import qualified Data.EventList.Relative.TimeBody as RTB
import           Data.Fixed                       (Milli)
import           Data.Foldable                    (toList)
import           Data.List.Extra                  (elemIndex, nubOrd, sort)
import           Data.List.NonEmpty               (NonEmpty (..))
import qualified Data.List.NonEmpty               as NE
import qualified Data.Map                         as Map
import           Data.Maybe                       (fromMaybe, listToMaybe)
import           Data.Profunctor                  (dimap)
import qualified Data.Text                        as T
import qualified Data.Vector                      as V
import           DeriveHelpers
import           DryVox                           (vocalTubes)
import           GHC.Generics                     (Generic)
import           Guitars                          (applyStatus1)
import qualified Numeric.NonNegative.Class        as NNC
import           RockBand.Codec
import           RockBand.Codec.ProGuitar
import           RockBand.Codec.Vocal
import           RockBand.Common                  hiding (RB3Instrument (..))
import           Rocksmith.ArrangementXML
import qualified Sound.MIDI.Util                  as U
import           Text.Read                        (readMaybe)
import           Text.Transform                   (showTimestamp)

data RocksmithTrack t = RocksmithTrack
  { rsNotes      :: RTB.T t (Edge GtrFret GtrString)
  , rsModifiers  :: RTB.T t ([GtrString], [RSModifier]) -- empty string lists = apply to all notes at this time
  , rsAnchorLow  :: RTB.T t GtrFret
  , rsAnchorHigh :: RTB.T t GtrFret -- if not given, defaults to low + 3 (for a width of 4)
  , rsTones      :: RTB.T t ToneLetter
  , rsBends      :: RTB.T t ([GtrString], Milli)
  , rsPhrases    :: RTB.T t T.Text -- phrase name; repeat same name for multiple iterations of one phrase
  , rsSections   :: RTB.T t T.Text
  , rsHandShapes :: RTB.T t (Edge GtrFret GtrString)
  , rsChords     :: RTB.T t ChordInfo
  } deriving (Eq, Ord, Show, Generic)
    deriving (Semigroup, Monoid, Mergeable) via GenericMerge (RocksmithTrack t)

data ChordInfo = ChordInfo
  { ciLocation :: ChordLocation
  , ciFingers  :: [Finger] -- low string to high
  , ciArpeggio :: Bool
  , ciNop      :: Bool -- I don't know what this is but it's a flag in the sng chord
  , ciName     :: Maybe T.Text
  } deriving (Eq, Ord, Show)

data ChordLocation
  = ChordLocNotes
  | ChordLocShape
  | ChordLocAll
  deriving (Eq, Ord, Show)

data ToneLetter = ToneA | ToneB | ToneC | ToneD
  deriving (Eq, Ord, Show, Enum, Bounded)

data Finger
  = FingerThumb
  | FingerIndex
  | FingerMiddle
  | FingerRing
  | FingerPinky
  deriving (Eq, Ord, Show, Enum)

data RSModifier
  = ModSustain -- forces sustain even if short midi note
  | ModVibrato Int -- strength? seen 40, 80, maybe others
  | ModHammerOn
  | ModPullOff
  | ModSlide Int -- fret
  | ModSlideUnpitch Int -- fret
  | ModMute
  | ModPalmMute
  | ModAccent
  | ModLink
  | ModHarmonic
  | ModHarmonicPinch
  -- left hand info is in rsChords
  | ModRightHand Finger
  -- these next 3 might have an extra int parameter in xml/sng? no idea if it matters
  | ModTap
  | ModSlap
  | ModPluck
  | ModTremolo
  | ModPickUp
  | ModPickDown
  | ModIgnore
  deriving (Eq, Ord, Show)

instance TraverseTrack RocksmithTrack where
  traverseTrack fn (RocksmithTrack a b c d e f g h i j) = RocksmithTrack
    <$> fn a <*> fn b <*> fn c <*> fn d <*> fn e <*> fn f <*> fn g <*> fn h
    <*> fn i <*> fn j

parseStrings :: [T.Text] -> Maybe ([GtrString], [T.Text])
parseStrings = \case
  "*" : rest -> Just ([], rest)
  ns  : rest | T.all isDigit ns -> do
    strs <- forM (T.unpack ns) $ \n -> lookup n
      [('0', S6), ('1', S5), ('2', S4), ('3', S3), ('4', S2), ('5', S1)]
    Just (strs, rest)
  rest -> Just ([], rest)

unparseStrings :: [GtrString] -> T.Text
unparseStrings [] = "*"
unparseStrings strs = let
  eachStr = \case
    S1 -> '5'
    S2 -> '4'
    S3 -> '3'
    S4 -> '2'
    S5 -> '1'
    S6 -> '0'
    -- don't make sense
    S7 -> 'F'
    S8 -> 'E'
  in T.pack $ map eachStr strs

lookupFinger :: T.Text -> Maybe Finger
lookupFinger = \case
  "T" -> Just FingerThumb
  "0" -> Just FingerThumb
  "1" -> Just FingerIndex
  "2" -> Just FingerMiddle
  "3" -> Just FingerRing
  "4" -> Just FingerPinky
  _   -> Nothing

parseModifiers :: [T.Text] -> Maybe ([GtrString], [RSModifier])
parseModifiers cmd = let
  go = \case
    [] -> Just []
    "sustain"       :     rest -> cont rest $ pure ModSustain
    "vibrato"       : n : rest -> cont rest $      ModVibrato <$> readMaybe (T.unpack n)
    "hammeron"      :     rest -> cont rest $ pure ModHammerOn
    "pulloff"       :     rest -> cont rest $ pure ModPullOff
    "slide"         : n : rest -> cont rest $      ModSlide <$> readMaybe (T.unpack n)
    "slideunpitch"  : n : rest -> cont rest $      ModSlideUnpitch <$> readMaybe (T.unpack n)
    "mute"          :     rest -> cont rest $ pure ModMute
    "palmmute"      :     rest -> cont rest $ pure ModPalmMute
    "accent"        :     rest -> cont rest $ pure ModAccent
    "link"          :     rest -> cont rest $ pure ModLink
    "harmonic"      :     rest -> cont rest $ pure ModHarmonic
    "harmonicpinch" :     rest -> cont rest $ pure ModHarmonicPinch
    "righthand"     : f : rest -> cont rest $      ModRightHand <$> lookupFinger f
    "tap"           :     rest -> cont rest $ pure ModTap
    "slap"          :     rest -> cont rest $ pure ModSlap
    "pluck"         :     rest -> cont rest $ pure ModPluck
    "tremolo"       :     rest -> cont rest $ pure ModTremolo
    "pickup"        :     rest -> cont rest $ pure ModPickUp
    "pickdown"      :     rest -> cont rest $ pure ModPickDown
    "ignore"        :     rest -> cont rest $ pure ModIgnore
    _                          -> Nothing
    where cont rest mx = (:) <$> mx <*> go rest
  in do
    (strs, rest) <- parseStrings cmd
    mods <- go rest
    Just (strs, mods)

unparseModifiers :: ([GtrString], [RSModifier]) -> [T.Text]
unparseModifiers (strs, mods) = let
  eachMod = \case
    ModSustain        -> ["sustain"                       ]
    ModVibrato n      -> ["vibrato"      , T.pack $ show n]
    ModHammerOn       -> ["hammeron"                      ]
    ModPullOff        -> ["pulloff"                       ]
    ModSlide n        -> ["slide"        , T.pack $ show n]
    ModSlideUnpitch n -> ["slideunpitch" , T.pack $ show n]
    ModMute           -> ["mute"                          ]
    ModPalmMute       -> ["palmmute"                      ]
    ModAccent         -> ["accent"                        ]
    ModLink           -> ["link"                          ]
    ModHarmonic       -> ["harmonic"                      ]
    ModHarmonicPinch  -> ["harmonicpinch"                 ]
    ModRightHand f    -> ["righthand"    , T.pack $ show $ fromEnum f]
    ModTap            -> ["tap"                           ]
    ModSlap           -> ["slap"                          ]
    ModPluck          -> ["pluck"                         ]
    ModTremolo        -> ["tremolo"                       ]
    ModPickUp         -> ["pickup"                        ]
    ModPickDown       -> ["pickdown"                      ]
    ModIgnore         -> ["ignore"                        ]
  in unparseStrings strs : (mods >>= eachMod)

parseBend :: [T.Text] -> Maybe ([GtrString], Milli)
parseBend cmd = do
  (strs, rest) <- parseStrings cmd
  bend <- case rest of
    ["bend", x] -> readMaybe $ T.unpack x
    _           -> Nothing
  Just (strs, bend)

unparseBend :: ([GtrString], Milli) -> [T.Text]
unparseBend (strs, bend) = [unparseStrings strs, "bend", T.pack $ show bend]

parseChord :: [T.Text] -> Maybe ChordInfo
parseChord = go where
  go = \case
    "chord" : xs -> parseLocation xs
    _            -> Nothing
  parseLocation = \case
    "notes" : xs -> parseFingers ChordLocNotes xs
    "shape" : xs -> parseFingers ChordLocShape xs
    xs           -> parseFingers ChordLocAll xs
  parseFingers loc = \case
    "_" : xs -> parseArp loc [] xs
    x   : xs -> do
      fingers <- mapM lookupFinger $ map T.singleton $ T.unpack x
      parseArp loc fingers xs
    _        -> Nothing
  parseArp loc fingers = \case
    "arp" : xs -> parseNop loc fingers True xs
    xs         -> parseNop loc fingers False xs
  parseNop loc fingers arp = \case
    "nop" : xs -> parseName loc fingers arp True xs
    xs         -> parseName loc fingers arp False xs
  parseName loc fingers arp nop = Just . \case
    [] -> ChordInfo loc fingers arp nop Nothing
    xs -> ChordInfo loc fingers arp nop $ Just $ T.unwords xs

unparseChord :: ChordInfo -> [T.Text]
unparseChord ChordInfo{..} = concat
  [ ["chord"]
  , case ciLocation of
    ChordLocAll   -> []
    ChordLocNotes -> ["notes"]
    ChordLocShape -> ["shape"]
  , case ciFingers of
    [] -> ["_"]
    _  -> [T.pack $ ciFingers >>= show . fromEnum]
  , ["arp" | ciArpeggio]
  , ["nop" | ciNop]
  , maybe [] T.words ciName
  ]

instance ParseTrack RocksmithTrack where
  parseTrack = do
    let parseNotes root = let
          fs = \case
            EdgeOn fret str -> (str, (0, Just $ fret + 100))
            EdgeOff str -> (str, (0, Nothing))
          fp = \case
            (str, (_, Just v)) -> EdgeOn (v - 100) str
            (str, (_, Nothing)) -> EdgeOff str
          in dimap (fmap fs) (fmap fp) $ condenseMap $ eachKey each $ \str -> edgesCV $ root + getStringIndex 6 str
    rsNotes      <- rsNotes =. parseNotes 96
    rsModifiers  <- rsModifiers =. commandMatch' parseModifiers unparseModifiers
    let fretNumber n = let
          fs fret = (0, fret + 100)
          fp (_c, v) = v - 100
          in fatBlips (1/8) $ dimap (fmap fs) (fmap fp) $ blipCV n
    rsTones      <- (rsTones =.) $ condenseMap_ $ eachKey each $ commandMatch . \case
      ToneA -> ["tone", "a"]
      ToneB -> ["tone", "b"]
      ToneC -> ["tone", "c"]
      ToneD -> ["tone", "d"]
    rsBends      <- rsBends      =. commandMatch' parseBend unparseBend
    rsPhrases    <- rsPhrases    =. commandMatch'
      (\case
        ["phrase", x] -> Just x
        _             -> Nothing
      )
      (\x -> ["phrase", x])
    rsSections   <- rsSections   =. commandMatch'
      (\case
        ["section", x] -> Just x
        _              -> Nothing
      )
      (\x -> ["section", x])
    rsHandShapes <- rsHandShapes =. parseNotes 84
    rsChords     <- rsChords     =. commandMatch' parseChord unparseChord
    (rsAnchorLow, rsAnchorHigh) <- statusBlips $ liftA2 (,)
      (rsAnchorLow  =. fretNumber 108)
      (rsAnchorHigh =. fretNumber 109)
    return RocksmithTrack{..}

data RSOutput = RSOutput
  { rso_level            :: Level
  , rso_tones            :: RTB.T U.Seconds ToneLetter
  , rso_sections         :: V.Vector Section
  , rso_phrases          :: V.Vector Phrase
  , rso_phraseIterations :: V.Vector PhraseIteration
  , rso_chordTemplates   :: V.Vector ChordTemplate
  }

data ChordBank = ChordBank
  { cb_notes  :: Map.Map (Map.Map GtrString GtrFret) ChordInfo
  , cb_shapes :: Map.Map (Map.Map GtrString GtrFret) ChordInfo
  }

data ChordsEvent
  = CENote (GtrString, GtrFret)
  | CEShape (GtrString, GtrFret)
  | CEChord ChordInfo
  deriving (Eq, Ord)

buildChordBank :: (NNC.C t) => RocksmithTrack t -> RTB.T t ChordBank
buildChordBank trk = let
  events = foldr RTB.merge RTB.empty
    [ RTB.mapMaybe (\case EdgeOn f s -> Just $ CENote (s, f); _ -> Nothing) $ rsNotes trk
    , RTB.mapMaybe (\case EdgeOn f s -> Just $ CEShape (s, f); _ -> Nothing) $ rsHandShapes trk
    , fmap CEChord $ rsChords trk
    ]
  go _    RNil               = RNil
  go bank (Wait t evts rest) = let
    funs = do
      CEChord ci <- evts
      concat
        [ do
          guard $ ciLocation ci /= ChordLocShape
          let notes = [n | CENote n <- evts]
          guard $ length notes >= 2
          return $ \b -> b { cb_notes = Map.insert (Map.fromList notes) ci $ cb_notes b }
        , do
          guard $ ciLocation ci /= ChordLocNotes
          let shapes = [n | CEShape n <- evts]
          guard $ length shapes >= 2
          return $ \b -> b { cb_shapes = Map.insert (Map.fromList shapes) ci $ cb_shapes b }
        ]
    bank' = foldr ($) bank funs
    in Wait t bank' $ go bank' rest
  in go (ChordBank Map.empty Map.empty) $ RTB.collectCoincident events

data FretConstraint
  = FretRelease ConstraintString
  | FretBlip    ConstraintString GtrFret
  | FretHold    ConstraintString GtrFret
  | FretZero -- just used to ensure that we make an anchor even if the first note is open
  deriving (Eq, Ord)

data ConstraintString
  = NoteString  Int
  | ShapeString Int
  deriving (Eq, Ord)

initialAnchor :: ATB.T U.Seconds FretConstraint -> (Int, Int)
initialAnchor consts = let
  frets = map (\fs -> (minimum fs, maximum fs)) $ ATB.getBodies $ ATB.collectCoincident $ flip ATB.mapMaybe consts $ \case
    FretBlip _ f -> Just f
    FretHold _ f -> Just f
    _            -> Nothing
  go possibleMins []                          = (NE.head possibleMins, NE.head possibleMins + 3)
  go possibleMins ((nextMin, nextMax) : rest) = let
    valid anchorMin = anchorMin <= nextMin && nextMax <= anchorMin + 3
    in case NE.nonEmpty $ NE.filter valid possibleMins of
      Nothing          -> (NE.head possibleMins, NE.head possibleMins + 3)
      Just newPossible -> go newPossible rest
  in case frets of
    []                                       -> (1, 4)
    first@(fmin, fmax) : _ | fmax - fmin > 3 -> first
    _                                        -> go (1 :| [2..21]) frets

autoAnchors :: [Note] -> [(ChordTemplate, U.Seconds, U.Seconds)] -> Map.Map U.Seconds (GtrFret, GtrFret)
autoAnchors allNotes shapes = let
  noteConstraints = ATB.fromPairList $ sort $ allNotes >>= \note ->
    case n_fret note of
      0 -> [(n_time note, FretZero)]
      _ -> case n_sustain note of
        Nothing -> [(n_time note, FretBlip (NoteString $ n_string note) (n_fret note))]
        Just sust -> concat
          [ [(n_time note, FretHold (NoteString $ n_string note) (n_fret note))]
          , [(n_time note <> sust, FretRelease $ NoteString $ n_string note)]
          , case n_slideTo note <|> n_slideUnpitchTo note of
            Just slide -> [(n_time note <> sust, FretBlip (NoteString $ n_string note) slide)]
            Nothing -> []
          ]
  shapeConstraints = ATB.fromPairList $ sort $ shapes >>= \(template, tstart, tend) -> let
    pairs = do
      (str, mfret) <-
        [ (0, ct_fret0 template)
        , (1, ct_fret1 template)
        , (2, ct_fret2 template)
        , (3, ct_fret3 template)
        , (4, ct_fret4 template)
        , (5, ct_fret5 template)
        ]
      fret <- toList mfret
      guard $ fret /= 0
      return (str, fret)
    in case pairs of
      [] -> [(tstart, FretZero)]
      _  -> do
        (str, fret) <- pairs
        [(tstart, FretHold (ShapeString str) fret), (tend, FretRelease $ ShapeString str)]
  constraints = ATB.merge noteConstraints shapeConstraints
  buildAnchors _ _ ANil = ANil
  buildAnchors prevAnchor@(prevMin, prevMax) fretState (At t evts rest) = let
    released = foldr Map.delete fretState [ s | FretRelease s <- evts ]
    permState = foldr (uncurry Map.insert) released [ (s, f) | FretHold s f <- evts ]
    fretsNow = case Map.elems $ foldr (uncurry Map.insert) permState [ (s, f) | FretBlip s f <- evts ] of
      []    -> Nothing
      frets -> Just (minimum frets, maximum frets)
    thisAnchor = case fretsNow of
      Nothing -> (prevMin, min (prevMin + 3) prevMax) -- shrink if more wide than usual
      Just (minFret, maxFret) -> case (prevMin <= minFret, maxFret <= prevMax) of
        (True, True)   -> if prevMax - prevMin == 3
          then prevAnchor -- continue previous anchor because it works
          else let
            -- shrink anchor, previous extra width not needed anymore
            thisMin = min minFret $ prevMax - 3
            thisMax = max (thisMin + 3) maxFret
            in (thisMin, thisMax)
        (True, False)  -> (min minFret (maxFret - 3), maxFret) -- need to move up
        (False, True)  -> (minFret, max (minFret + 3) maxFret) -- need to move down
        (False, False) -> (minFret, maxFret) -- need to grow
    in At t thisAnchor $ buildAnchors thisAnchor permState rest
  in Map.fromList $ ATB.toPairList
    $ RTB.toAbsoluteEventList 0
    $ noRedundantStatus
    $ RTB.fromAbsoluteEventList
    $ buildAnchors (initialAnchor constraints) Map.empty
    $ ATB.collectCoincident constraints

backportAnchors :: U.TempoMap -> RocksmithTrack U.Beats -> RSOutput -> RocksmithTrack U.Beats
backportAnchors tmap trk rso = let
  anchors
    = U.unapplyTempoTrack tmap
    $ RTB.fromAbsoluteEventList
    $ ATB.fromPairList
    $ sort
    $ map (\a -> (an_time a, (an_fret a, an_fret a + an_width a - 1)))
    $ toList $ lvl_anchors $ rso_level rso
  in trk
    { rsAnchorLow  = fmap fst anchors
    , rsAnchorHigh = fmap snd anchors
    }

buildRS :: (SendMessage m) => U.TempoMap -> RocksmithTrack U.Beats -> StackTraceT m RSOutput
buildRS tmap trk = do
  let insideTime t = inside $ T.unpack $ showTimestamp t
      numberSections _ [] = []
      numberSections counts ((t, sect) : rest) = let
        n = fromMaybe 0 $ Map.lookup sect counts
        thisSection = Section
          { sect_name = sect
          , sect_number = n + 1
          , sect_startTime = U.applyTempoMap tmap t
          }
        counts' = Map.insert sect (n + 1) counts
        in thisSection : numberSections counts' rest
      uniquePhrases = nubOrd $ toList $ rsPhrases trk
      modifierMap = Map.fromList $ ATB.toPairList $ RTB.toAbsoluteEventList 0
        $ RTB.collectCoincident $ U.applyTempoTrack tmap $ rsModifiers trk
      lookupModifier t str = let
        atTime = fromMaybe [] $ Map.lookup t modifierMap
        in concat [ mods | (strs, mods) <- atTime, null strs || elem str strs ]
      bendMap = Map.fromList $ ATB.toPairList $ RTB.toAbsoluteEventList 0
        $ RTB.collectCoincident $ U.applyTempoTrack tmap $ rsBends trk
      lookupBends t len str = let
        (_, startBend, m1) = Map.splitLookup t bendMap
        (m2, endBend, _) = Map.splitLookup (t <> len) m1
        m3 = maybe id (Map.insert t) startBend
          $ maybe id (Map.insert $ t <> len) endBend m2
        -- TODO do we need a separate event for "bends right at the end of a sustain"?
        in do
          (bendTime, evts) <- Map.toList m3
          (strs, bend) <- evts
          guard $ null strs || elem str strs
          return (bendTime, bend)
      makeNote t (fret, str, len) = let
        mods = lookupModifier t str
        bends = lookupBends t len str
        in Note
          { n_time           = t
          , n_string         = case str of
            S6 -> 0
            S5 -> 1
            S4 -> 2
            S3 -> 3
            S2 -> 4
            S1 -> 5
            _  -> -1
          , n_fret           = fret
          , n_sustain        = let
            startBeats = U.unapplyTempoMap tmap t
            endBeats = U.unapplyTempoMap tmap $ t <> len
            forcesSustain = \case
              ModSustain        -> True
              ModLink           -> True
              ModSlide _        -> True
              ModSlideUnpitch _ -> True
              _                 -> False
            in if endBeats - startBeats >= (1/3) || any forcesSustain mods
              then Just len
              else Nothing
          , n_vibrato        = listToMaybe [ n | ModVibrato n <- mods ]
          , n_hopo           = False -- I don't think you need this?
          , n_hammerOn       = elem ModHammerOn mods
          , n_pullOff        = elem ModPullOff mods
          , n_slideTo        = listToMaybe [ n | ModSlide n <- mods ]
          , n_slideUnpitchTo = listToMaybe [ n | ModSlideUnpitch n <- mods ]
          , n_mute           = elem ModMute mods
          , n_palmMute       = elem ModPalmMute mods
          , n_accent         = elem ModAccent mods
          , n_linkNext       = elem ModLink mods
          , n_bend           = case bends of
            [] -> Nothing
            _  -> Just $ maximum $ map snd bends
          , n_bendValues     = V.fromList $ flip map bends $ \(bendTime, bend) -> BendValue
            { bv_time = bendTime
            , bv_step = Just bend
            }
          , n_harmonic       = elem ModHarmonic mods
          , n_harmonicPinch  = elem ModHarmonicPinch mods
          , n_leftHand       = Nothing -- if chord, assigned later when we look up the chord info
          , n_rightHand      = listToMaybe [ fromEnum n | ModRightHand n <- mods ]
          , n_tap            = elem ModTap mods
          , n_slap           = if elem ModSlap mods then Just 1 else Nothing
          , n_pluck          = if elem ModPluck mods then Just 1 else Nothing
          , n_tremolo        = elem ModTremolo mods
          , n_pickDirection  = Nothing -- TODO
          , n_ignore         = elem ModIgnore mods || fret > 22
          -- frets 23 and 24, you need to set to ignore or the scoring doesn't work right (can't get 100%).
          -- EOF does the same thing
          }
      chordBank = Map.fromList $ ATB.toPairList $ RTB.toAbsoluteEventList 0 $ U.applyTempoTrack tmap $ buildChordBank trk
      makeTemplate cinfo notes = let
        sortedNotes = sort [(str, fret) | (fret, str, _) <- notes]
        assignFingers []       []                = return []
        assignFingers []       ns                = do
          when (any ((/= 0) . snd) ns) $ warn $ "No fingers assigned for chord: " <> show ns
          return []
        assignFingers fs       ((str, 0) : rest) = ((str, 0, Nothing) :) <$> assignFingers fs rest
        assignFingers (f : fs) ((str, n) : rest) = ((str, n, Just f ) :) <$> assignFingers fs rest
        assignFingers _        _                 = fatal $ unwords
          [ "Mismatched chord fingers: can't match"
          , show notes
          , "with"
          , show cinfo
          ]
        finish assigned = ChordTemplate
          { ct_chordName   = fromMaybe "" $ ciName cinfo
          , ct_displayName = fromMaybe "" (ciName cinfo)
            <> (if ciArpeggio cinfo then "-arp" else "")
            <> (if ciNop      cinfo then "-nop" else "")
          , ct_finger0     = listToMaybe [fromEnum finger | (S6, _, Just finger) <- assigned]
          , ct_finger1     = listToMaybe [fromEnum finger | (S5, _, Just finger) <- assigned]
          , ct_finger2     = listToMaybe [fromEnum finger | (S4, _, Just finger) <- assigned]
          , ct_finger3     = listToMaybe [fromEnum finger | (S3, _, Just finger) <- assigned]
          , ct_finger4     = listToMaybe [fromEnum finger | (S2, _, Just finger) <- assigned]
          , ct_finger5     = listToMaybe [fromEnum finger | (S1, _, Just finger) <- assigned]
          , ct_fret0       = listToMaybe [fret | (S6, fret, _) <- assigned]
          , ct_fret1       = listToMaybe [fret | (S5, fret, _) <- assigned]
          , ct_fret2       = listToMaybe [fret | (S4, fret, _) <- assigned]
          , ct_fret3       = listToMaybe [fret | (S3, fret, _) <- assigned]
          , ct_fret4       = listToMaybe [fret | (S2, fret, _) <- assigned]
          , ct_fret5       = listToMaybe [fret | (S1, fret, _) <- assigned]
          }
        in finish <$> assignFingers (ciFingers cinfo) sortedNotes
      -- TODO need to handle cases where e.g. you have 2 simultaneous notes,
      -- but one is a actually linked to the previous note on that string.
      -- see Lost Keys/Rosetta Stoned by shinyditto12.
      -- I think we also need to have [chord] constructs apply to certain strings
  notesAndChords <- let
    notes = RTB.collectCoincident $ joinEdgesSimple $ U.applyTempoTrack tmap $ rsNotes trk
    in fmap concat $ forM (ATB.toPairList $ RTB.toAbsoluteEventList 0 $ notes) $ \(t, noteGroup) -> insideTime t $ do
      case noteGroup of
        [triple] -> return [Left $ makeNote t triple]
        _        -> case [ len | (_, _, len) <- noteGroup ] of
          x : xs | any (/= x) xs ->
            -- uneven lengths, emit as single notes. e.g. unison bend in 25 or 6 to 4 Lead
            return $ map (Left . makeNote t) noteGroup
          _ -> let
            key = Map.fromList [ (str, fret) | (fret, str, _) <- noteGroup ]
            in case Map.lookupLE t chordBank >>= Map.lookup key . cb_notes . snd of
              Just cinfo -> do
                template <- makeTemplate cinfo noteGroup
                let madeNotes = do
                      triple <- noteGroup
                      let note = makeNote t triple
                      return note
                        { n_leftHand = case n_string note of
                          0 -> ct_finger0 template
                          1 -> ct_finger1 template
                          2 -> ct_finger2 template
                          3 -> ct_finger3 template
                          4 -> ct_finger4 template
                          5 -> ct_finger5 template
                          _ -> Nothing
                        }
                return [Right (template, madeNotes)]
              Nothing -> do
                warn $ "Not making simultaneous notes into a chord due to no chord mapping:  " <> show key
                return $ map (Left . makeNote t) noteGroup
      -- note: if you have any chords in the notes, you need at least one handshape, otherwise CST crashes
  shapes <- let
    shapeNotes = RTB.collectCoincident $ joinEdgesSimple $ U.applyTempoTrack tmap $ rsHandShapes trk
    in forM (ATB.toPairList $ RTB.toAbsoluteEventList 0 $ shapeNotes) $ \(t, noteGroup) -> insideTime t $ let
      key = Map.fromList [ (str, fret) | (fret, str, _) <- noteGroup ]
      in case Map.lookupLE t chordBank >>= Map.lookup key . cb_shapes . snd of
        Just cinfo -> do
          template <- makeTemplate cinfo noteGroup
          let startTime = t
              endTime = t <> case head noteGroup of (_, _, len) -> len
          return (template, startTime, endTime)
        Nothing -> fatal $ "Couldn't find handshape chord mapping for " <> show key
  let allNotes = notesAndChords >>= \case
        Left  note       -> [note]
        Right (_, notes) -> notes
      chordTemplates = nubOrd
        $  [ template | Right (template, _) <- notesAndChords ]
        <> [ template | (template, _, _)    <- shapes         ]
      chordTemplateIndexes = Map.fromList $ zip chordTemplates [0..]
  case length $ rsPhrases trk of
    n -> when (n > 100) $ warn $ "There are " <> show n <> " phrases; more than 100 phrases won't display correctly in game"
  return RSOutput
    { rso_level = Level
      { lvl_difficulty    = 0
      , lvl_notes         = V.fromList [ n | Left n <- notesAndChords ]
      , lvl_chords        = V.fromList $ do
        Right (template, notes) <- notesAndChords
        return Chord
          { chd_time         = n_time $ head notes
          , chd_chordId      = fromMaybe (-1) $ Map.lookup template chordTemplateIndexes
          , chd_accent       = all n_accent notes
          , chd_highDensity  = False -- TODO what does this do exactly? is it visual or scoring?
          , chd_palmMute     = all n_palmMute notes
          , chd_fretHandMute = all n_mute notes
          , chd_linkNext     = all n_linkNext notes
          , chd_chordNotes   = V.fromList notes
          , chd_ignore       = all n_ignore notes
          , chd_hopo         = False -- is this required?
          , chd_strum        = Nothing -- TODO get from n_pickDirection
          }
      , lvl_handShapes    = V.fromList $ do
        (template, startTime, endTime) <- shapes
        return HandShape
          { hs_chordId   = fromMaybe (-1) $ Map.lookup template chordTemplateIndexes
          , hs_startTime = startTime
          , hs_endTime   = endTime
          }
      , lvl_fretHandMutes = mempty
      , lvl_anchors       = let
        -- note: according to EOF, highest min-fret for an anchor is 21
        anchorMap = if RTB.null $ rsAnchorLow trk
          then autoAnchors allNotes shapes
          else let
            merged = RTB.collectCoincident $ RTB.merge (Left <$> rsAnchorLow trk) (Right <$> rsAnchorHigh trk)
            bounds = U.applyTempoTrack tmap $ flip RTB.mapMaybe merged $ \evts ->
              case ([ low | Left low <- evts ], [ high | Right high <- evts ]) of
                (low : _, high : _) -> Just (low, high)
                (low : _, []      ) -> Just (low, low + 3)
                _                   -> Nothing
            in Map.fromList $ ATB.toPairList $ RTB.toAbsoluteEventList 0 $ noRedundantStatus bounds
        -- each phrase needs to have an anchor at the start (or at least before its first note)
        addPhraseAnchors m []   = m
        addPhraseAnchors m (t : ts) = case Map.lookupLE t m of
          Nothing          -> addPhraseAnchors m ts
          Just (_, anchor) -> addPhraseAnchors (Map.insert t anchor m) ts
        anchorMap' = addPhraseAnchors anchorMap $ ATB.getTimes
          $ RTB.toAbsoluteEventList 0 $ U.applyTempoTrack tmap $ rsPhrases trk
        in V.fromList $ flip map (Map.toList anchorMap') $ \(t, (low, high)) -> Anchor
          { an_time  = t
          , an_fret  = low
          , an_width = max 1 $ high - low + 1
          }
      }
    , rso_tones = U.applyTempoTrack tmap $ rsTones trk
    , rso_sections = V.fromList $ numberSections Map.empty
      $ ATB.toPairList $ RTB.toAbsoluteEventList 0 $ rsSections trk
    , rso_phrases = V.fromList $ flip map uniquePhrases $ \phrase -> Phrase
      { ph_maxDifficulty = 0
      , ph_name          = phrase
      , ph_disparity     = Nothing
      , ph_ignore        = False
      , ph_solo          = False
      }
    , rso_phraseIterations
      = V.fromList
      $ map (\(t, phrase) -> PhraseIteration
        { pi_time       = U.applyTempoMap tmap t
        , pi_phraseId   = fromMaybe (-1) $ elemIndex phrase uniquePhrases
        , pi_variation  = Nothing
        , pi_heroLevels = V.empty
        })
      $ ATB.toPairList
      $ RTB.toAbsoluteEventList 0
      $ rsPhrases trk
    , rso_chordTemplates = V.fromList chordTemplates
    }

data VocalEvent
  = VocalNoteEnd
  | VocalPhraseEnd
  | VocalNote T.Text Int
  deriving (Eq, Ord) -- constructor order is important

buildRSVocals :: U.TempoMap -> VocalTrack U.Beats -> Vocals
buildRSVocals tmap vox = Vocals $ V.fromList $ let
  tubes = vocalTubes vox
  pitches = fmap fst $ RTB.filter snd $ vocalNotes vox
  tubeEvents = flip fmap (applyStatus1 (Octave60 C) pitches tubes) $ \case
    (p, Just lyric) -> VocalNote lyric $ 36 + fromEnum p
    (_, Nothing   ) -> VocalNoteEnd
  phraseEnds = RTB.filter not $ RTB.merge (vocalPhrase1 vox) (vocalPhrase2 vox)
  evts = U.applyTempoTrack tmap $ RTB.normalize $
    RTB.merge tubeEvents $ fmap (const VocalPhraseEnd) phraseEnds
  go = \case
    Wait dt1 (VocalNote lyric pitch) (Wait dt2 VocalNoteEnd rest) -> let
      lyric1 = fromMaybe lyric $ T.stripSuffix "#" lyric <|> T.stripSuffix "^" lyric
      lyric2 = case T.stripSuffix "=" lyric1 of
        Just x  -> x <> "-"
        Nothing -> lyric1
      lyric3 = case rest of
        Wait _ VocalPhraseEnd _ -> lyric2 <> "+"
        _                       -> lyric2
      -- probably don't need to handle $ because this only runs on PART VOCALS.
      -- TODO maybe fix the weird "two vowels in one syllable" char
      noteFn = \t -> Vocal
        { voc_time = t
        , voc_note = pitch
        , voc_length = dt2
        , voc_lyric = lyric3
        }
      in Wait dt1 noteFn $ RTB.delay dt2 $ go rest
    Wait dt _ rest -> RTB.delay dt $ go rest
    RNil -> RNil
  in map (\(t, f) -> f t) $ ATB.toPairList $ RTB.toAbsoluteEventList 0 $ go evts