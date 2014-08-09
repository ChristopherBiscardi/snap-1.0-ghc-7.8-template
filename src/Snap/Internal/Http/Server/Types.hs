{-# LANGUAGE RankNTypes #-}
------------------------------------------------------------------------------
-- | Types internal to the implementation of the Snap HTTP server.
module Snap.Internal.Http.Server.Types
  ( ServerConfig(..)
  , PerSessionData(..)
  , DataFinishedHook
  , EscapeSnapHook
  , ExceptionHook
  , ParseHook
  , NewRequestHook
  , UserHandlerFinishedHook

  -- * Handlers
  , SendFileHandler
  , ServerHandler
  , AcceptFunc(..)

  -- * Socket types
  , SocketConfig(..)
  ) where

------------------------------------------------------------------------------
import           Control.Exception                        (SomeException)
import           Data.ByteString                          (ByteString)
import           Data.IORef                               (IORef)
import           Data.Word                                (Word64)
import           Network.Socket                           (Socket)
------------------------------------------------------------------------------
import           Blaze.ByteString.Builder                 (Builder)
import           Blaze.ByteString.Builder.Internal.Buffer (Buffer)
import           System.IO.Streams                        (InputStream, OutputStream)
------------------------------------------------------------------------------
import           Snap.Core                                (Request, Response)


------------------------------------------------------------------------------
-- | The 'NewRequestHook' is called once processing for an HTTP request begins,
-- i.e. after the connection has been accepted and we know that there's data
-- available to read from the socket. The IORef passed to the hook initially
-- contains a bottom value that will throw an exception if evaluated.
type NewRequestHook hookState = PerSessionData -> IO hookState

-- | The 'ParseHook' is called after the HTTP Request has been parsed by the
-- server, but before the user handler starts running.
type ParseHook hookState = IORef hookState -> Request -> IO ()

-- | The 'UserHandlerFinishedHook' is called once the user handler has finished
-- running, but before the data for the HTTP response starts being sent to the
-- client.
type UserHandlerFinishedHook hookState =
    IORef hookState -> Request -> Response -> IO ()

-- | The 'DataFinishedHook' is called once the server has finished sending the
-- HTTP response to the client.
type DataFinishedHook hookState =
    IORef hookState -> Request -> Response -> IO ()

-- | The 'ExceptionHook' is called if an exception reaches the toplevel of the
-- server, i.e. if an exception leaks out of the user handler or if an
-- exception is raised during the sending of the HTTP response data.
type ExceptionHook hookState = IORef hookState -> SomeException -> IO ()

-- | The 'EscapeSnapHook' is called if the user handler escapes the HTTP
-- session, e.g. for websockets.
type EscapeSnapHook hookState = IORef hookState -> IO ()


                             ---------------------
                             -- data structures --
                             ---------------------
------------------------------------------------------------------------------
-- | Data and services that all HTTP response handlers share.
--
data ServerConfig hookState = ServerConfig
    { _logAccess             :: !(Request -> Response -> Word64 -> IO ())
    , _logError              :: !(Builder -> IO ())
    , _onNewRequest          :: !(NewRequestHook hookState)
    , _onParse               :: !(ParseHook hookState)
    , _onUserHandlerFinished :: !(UserHandlerFinishedHook hookState)
    , _onDataFinished        :: !(DataFinishedHook hookState)
    , _onException           :: !(ExceptionHook hookState)
    , _onEscape              :: !(EscapeSnapHook hookState)

      -- | will be overridden by a @Host@ header if it appears.
    , _localHostname         :: !ByteString
    , _defaultTimeout        :: {-# UNPACK #-} !Int
    , _isSecure              :: !Bool

      -- | Number of accept loops to spawn.
    , _numAcceptLoops        :: {-# UNPACK #-} !Int
    }


------------------------------------------------------------------------------
-- | All of the things a session needs to service a single HTTP request.
data PerSessionData = PerSessionData
    { -- | If the bool stored in this IORef becomes true, the server will close
      -- the connection after the current request is processed.
      _forceConnectionClose :: {-# UNPACK #-} !(IORef Bool)

      -- | An IO action to modify the current request timeout.
    , _twiddleTimeout       :: !((Int -> Int) -> IO ())

      -- | The value stored in this IORef is True if this request is the first
      -- on a new connection, and False if it is a subsequent keep-alive
      -- request.
    , _isNewConnection      :: !(IORef Bool)

      -- | The function called when we want to use @sendfile().@
    , _sendfileHandler      :: !SendFileHandler

      -- | The server's idea of its local address.
    , _localAddress         :: !ByteString

      -- | The listening port number.
    , _localPort            :: {-# UNPACK #-} !Int

      -- | The address of the remote user.
    , _remoteAddress        :: !ByteString

      -- | The remote user's port.
    , _remotePort           :: {-# UNPACK #-} !Int

      -- | The read end of the socket connection.
    , _readEnd              :: !(InputStream ByteString)

      -- | The write end of the socket connection.
    , _writeEnd             :: !(OutputStream ByteString)
    }


------------------------------------------------------------------------------
newtype AcceptFunc = AcceptFunc {
  runAcceptFunc :: (forall a . IO a -> IO a)         -- exception restore function
                    -> IO ( SendFileHandler          -- what to do on sendfile
                          , ByteString               -- local address
                          , Int                      -- local port
                          , ByteString               -- remote address
                          , Int                      -- remote port
                          , InputStream ByteString   -- socket read end
                          , OutputStream ByteString  -- socket write end
                          , IO ()                    -- cleanup action
                          )
  }

                             --------------------
                             -- function types --
                             --------------------
------------------------------------------------------------------------------
-- | This function, provided to the web server internals from the outside, is
-- responsible for producing a 'Response' once the server has parsed the
-- 'Request'.
--
type ServerHandler hookState =
        ServerConfig hookState     -- ^ global server config
     -> PerSessionData             -- ^ per-connection data
     -> Request                    -- ^ HTTP request object
     -> IO (Request, Response)


------------------------------------------------------------------------------
-- | A 'SendFileHandler' is called if the user handler requests that a file be
-- sent using @sendfile()@ on systems that support it (Linux, Mac OSX, and
-- FreeBSD).
type SendFileHandler =
       Buffer                   -- ^ builder buffer
    -> Builder                  -- ^ status line and headers
    -> FilePath                 -- ^ file to send
    -> Word64                   -- ^ start offset
    -> Word64                   -- ^ number of bytes
    -> IO ()



                        -------------------------------
                        -- types for server backends --
                        -------------------------------

------------------------------------------------------------------------------
-- | Either the server should start listening on the given interface \/ port
-- combination, or the server should start up with a 'Socket' that has already
-- had @bind()@ and @listen()@ called on it.
data SocketConfig = StartListening ByteString Int
                  | PreBound Socket
