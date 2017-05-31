{-# LANGUAGE CPP #-}
-- | OS-specific functions to open and show files.
module OSFiles (osOpenFile) where

import Control.Monad.IO.Class (MonadIO(..))
#ifdef WINDOWS
import System.Win32.Types (LPCWSTR, INT, HINSTANCE)
import Graphics.Win32.GDI.Types (HWND)
import Foreign (nullPtr, ptrToIntPtr)
import Foreign.C (withCWString)
#else
import           System.Info                    (os)
import           System.Process                 (callProcess)
import           System.IO.Silently             (hSilence)
import System.IO (stdout, stderr)
#endif

#ifdef WINDOWS

-- TODO this should be ccall on 64-bit, see Win32 package
foreign import stdcall unsafe "ShellExecuteW"
  c_ShellExecute :: HWND -> LPCWSTR -> LPCWSTR -> LPCWSTR -> LPCWSTR -> INT -> IO HINSTANCE

osOpenFile :: (MonadIO m) => FilePath -> m ()
osOpenFile f = liftIO $ withCWString f $ \wstr -> do
  n <- c_ShellExecute nullPtr nullPtr wstr nullPtr nullPtr 5
  if ptrToIntPtr n > 32
    then return ()
    else error $ "osOpenFile: ShellExecuteW return code " ++ show n

#else

osOpenFile :: (MonadIO m) => FilePath -> m ()
osOpenFile f = liftIO $ case os of
  -- "mingw32" -> void $ spawnCommand $ "\"" ++ f ++ "\""
  "darwin"  -> callProcess "open" [f]
  "linux"   -> hSilence [stdout, stderr] $ callProcess "exo-open" [f]
  _         -> return ()

#endif
