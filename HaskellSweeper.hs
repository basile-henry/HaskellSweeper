{-# LANGUAGE NamedFieldPuns #-}

module Main(main) where

import           Data.Hashable       (Hashable (hash))
import           Data.List           (intercalate)
import           Data.Set            (member)
import qualified Options.Applicative as Opt
import           Prelude             hiding (Either (..))
import qualified Prelude             as P
import           System.IO.Error     (tryIOError)
import qualified System.IO.Strict    as S
import           System.Random       (getStdGen)
import           UI.NCurses          (Color (..), ColorID, Curses, Event (..),
                                      Key (..), Update, Window, defaultWindow,
                                      drawLineH, drawString, getEvent,
                                      glyphLineH, moveCursor, newColorID,
                                      render, runCurses, setColor, setEcho,
                                      updateWindow, windowSize)

import           Sweeper.Game
import           Sweeper.Grid

{-# ANN module ("HLint: ignore Use head") #-}
-- we often use "palette !! x" for some x

showGrid :: GameState -> Panel -> Position -> [ColorID] -> Update ()
showGrid gamestate (Cartesian left top, Cartesian right bottom) (Cartesian sx sy) palette =
    sequence_ [do moveCursor (toInteger $ y - sy) (toInteger $ x - sx); showCell gamestate (Cartesian x y) palette | x<-[left..right], y<-[top..bottom]]

showCell :: GameState -> Position -> [ColorID] -> Update ()
showCell GameState{grid, visibility, markers, playState} pos palette
    | member pos markers    = do markerColor playState currentCell; drawString "#";
    | playState == Dead &&
      currentCell == Mine   = drawMine
    | member pos visibility = showCell' currentCell (tallyMines grid pos)
    | otherwise             = do setColor $ palette!!0; drawString " "
    where
        currentCell :: Cell
        currentCell = getCell grid pos

        showCell' :: Cell -> Int -> Update ()
        showCell' Mine  _ = drawMine
        showCell' Empty 0 = do setColor $ palette!!0; drawString "•";
        showCell' Empty t = do setColor $ palette!!t; drawString $ show t;

        drawMine :: Update ()
        drawMine = do setColor $ palette!!8; drawString "X";

        markerColor :: PlayState -> Cell -> Update ()
        markerColor Dead Empty = setColor $ palette!!2
        markerColor _    _     = setColor $ palette!!8

-- Highscore file path depends on the options
highscorePath :: Options -> FilePath
highscorePath options = ".highscore_" ++ show (hash options)

readHighscore :: Options -> IO Score
readHighscore options = do
    strOrExc <- tryIOError $ S.readFile $ highscorePath options
    let
        getScore :: [String] -> Score
        getScore []    = 0
        getScore (x:_) = read $ last $ words x

        highscore = case strOrExc of
            P.Left  _        -> 0
            P.Right contents -> getScore $ lines contents

    return highscore

writeHighscore :: Options -> Score -> IO ()
writeHighscore options score = writeFile (highscorePath options) (show score)

main :: IO ()
main = do
    gen  <- getStdGen
    options <- Opt.execParser $ Opt.info (Opt.helper <*> optionsParser) Opt.fullDesc
    highscore <- readHighscore options -- get the saved highscore

    -- Start the UI and the mainloop
    -- get the new highscore
    new_highscore <- runCurses $ do
        setEcho False -- prevent keyboard from writing in the terminal
        w <- defaultWindow
        -- get user defined colors (from the profile)
        palette <- sequence
            [
                newColorID ColorBlue    ColorDefault 1,
                newColorID ColorWhite   ColorDefault 2,
                newColorID ColorYellow  ColorDefault 3,
                newColorID ColorGreen   ColorDefault 4,
                newColorID ColorMagenta ColorDefault 5,
                newColorID ColorCyan    ColorDefault 6,
                newColorID ColorBlack   ColorDefault 7,
                newColorID ColorRed     ColorDefault 8,
                newColorID ColorRed     ColorDefault 9
            ]

        doUpdate w palette (createGameState gen options highscore)

    -- save the new highscore
    writeHighscore options new_highscore

-- Mainloop
-- Update the UI
doUpdate :: Window -> [ColorID] -> GameState -> Curses Score
doUpdate w palette g@GameState{position=Cartesian x y, score, highscore, playState, options} = do
    updateWindow w $ do
        (sizeY, sizeX) <- windowSize
        let topLeft@(Cartesian left top) = Cartesian (x - (sizeX `div` 2)) (y - (sizeY `div` 2))
        let bottomRight = Cartesian (left + sizeX - 1) (top + sizeY - 3)
        let panel = (topLeft, bottomRight)

        moveCursor 0 0
        showGrid g panel (Cartesian left top) palette
        moveCursor (sizeY - 2) 0
        setColor $ palette!!2
        drawLineH (Just glyphLineH) sizeX
        moveCursor (sizeY - 1) 0
        setColor $ palette!!0
        drawString $ take (fromInteger sizeX-1) $
            intercalate " | " (
                prettyShow options ++
                case playState of
                    Alive -> ["Score: " ++ show score]
                    Dead  -> ["Game over! Your score is: " ++ show score, "Highscore is: " ++ show highscore]
                )
            ++ repeat ' '
        moveCursor (div sizeY 2) (div sizeX 2)
    render
    inputUpdate w palette g

-- Take keyboard inputs and update GameState
inputUpdate :: Window -> [ColorID] -> GameState -> Curses Score
inputUpdate w palette g =
    getEvent w (Just 100) >>= maybe
        (doUpdate w palette g)
        (\key -> case stepGameWorld key g of
          Nothing -> pure (highscore g)
          Just g' -> doUpdate w palette g'
          )

-- Handle keyboard inputs on the current GameState and update the GameState accordingly
stepGameWorld :: Event -> GameUpdate
stepGameWorld event
    | event `elem` quitEvents          = const Nothing
    | event `elem` restartEvents       = pure . newGame 
    | event `elem` moveUpEvents        = makeMove Up
    | event `elem` moveDownEvents      = makeMove Down
    | event `elem` moveLeftEvents      = makeMove Left
    | event `elem` moveRightEvents     = makeMove Right
    | event `elem` moveUpLeftEvents    = makeMove UpLeft
    | event `elem` moveUpRightEvents   = makeMove UpRight
    | event `elem` moveDownLeftEvents  = makeMove DownLeft
    | event `elem` moveDownRightEvents = makeMove DownRight
    | event `elem` placeMarkerEvents   = placeMarker
    | event `elem` clickCellEvents     = clickCell
    | otherwise = pure
  where
    quitEvents          =                                 map EventCharacter "qQ"
    restartEvents       =                                 map EventCharacter "rR"
    moveUpEvents        = EventSpecialKey KeyUpArrow    : map EventCharacter "wWkK8"
    moveDownEvents      = EventSpecialKey KeyDownArrow  : map EventCharacter "sSjJ2"
    moveLeftEvents      = EventSpecialKey KeyLeftArrow  : map EventCharacter "aAhH4"
    moveRightEvents     = EventSpecialKey KeyRightArrow : map EventCharacter "dDlL6"
    moveUpLeftEvents    =                                 map EventCharacter "yY7"
    moveUpRightEvents   =                                 map EventCharacter "uU9"
    moveDownLeftEvents  =                                 map EventCharacter "bB1"
    moveDownRightEvents =                                 map EventCharacter "nN3"
    placeMarkerEvents   =                                 map EventCharacter "mMeE5"
    clickCellEvents     = EventSpecialKey KeyEnter      : map EventCharacter " 0"
