//+------------------------------------------------------------------+
//| CopyTrading/SignalReceiver.mqh                                   |
//| Receives trade signals from master via file system polling       |
//+------------------------------------------------------------------+
#pragma once
#include "Defines.mqh"
#include "Logger.mqh"
#include "Signal.mqh"

//+------------------------------------------------------------------+
//| CSignalReceiver                                                  |
//| Polls the shared signal directory for new signal files written   |
//| by CSignalBroadcaster, de-duplicates them, and provides a FIFO  |
//| queue from which the Follower EA dequeues and executes trades.   |
//| Monitors the master heartbeat file to track connection status.   |
//+------------------------------------------------------------------+
class CSignalReceiver
  {
private:
   string                 m_masterId;           // Master account identifier
   string                 m_followerId;         // This follower's unique identifier
   string                 m_signalDir;          // Shared signal directory path
   string                 m_stateFile;          // Path to the processed-IDs state file
   CSignal                m_queue[];            // Circular FIFO pending signal buffer
   int                    m_queueHead;          // Index of the next signal to dequeue
   int                    m_queueTail;          // Index where the next signal will be written
   int                    m_queueCount;         // Number of signals currently in the queue
   string                 m_processedIds[];     // Ring-buffer of last 200 processed IDs
   int                    m_processedCount;     // Total IDs written so far (monotonic)
   ENUM_CONNECTION_STATUS m_status;             // Current connection status
   datetime               m_lastHeartbeat;      // Timestamp read from master heartbeat file
   datetime               m_lastPoll;           // Time of most recent Poll() call
   CLogger               *m_logger;             // Shared logger (not owned)
   int                    m_totalReceived;      // Signals successfully enqueued
   int                    m_totalSkipped;       // Signals discarded (stale / duplicate)

   //--- Private helpers
   void                   CheckHeartbeat();
   void                   ScanSignalFiles();
   void                   ProcessSignalFile(string filename);
   void                   EnqueueSignal(const CSignal &signal);
   bool                   IsAlreadyProcessed(string signalId) const;
   void                   MarkProcessed(string signalId);
   void                   LoadProcessedIds();
   void                   SetStatus(ENUM_CONNECTION_STATUS status);
   string                 ExtractSignalId(const string &filename) const;

public:
                          CSignalReceiver();

   bool                   Init(CLogger *logger, string masterId, string followerId);
   void                   Poll();
   bool                   DequeueSignal(CSignal &signal);
   bool                   HasPendingSignals() const  { return m_queueCount > 0;              }

   ENUM_CONNECTION_STATUS GetStatus()        const  { return m_status;                       }
   bool                   IsConnected()      const  { return m_status == CONN_CONNECTED ||
                                                             m_status == CONN_DEGRADED;       }
   int                    GetQueueCount()    const  { return m_queueCount;                   }
   int                    GetTotalReceived() const  { return m_totalReceived;                }
   int                    GetTotalSkipped()  const  { return m_totalSkipped;                 }
   string                 GetStatusString()  const;
  };

//+------------------------------------------------------------------+
//| Constructor — zero-initialise all members                        |
//+------------------------------------------------------------------+
CSignalReceiver::CSignalReceiver()
  {
   m_masterId        = "";
   m_followerId      = "";
   m_signalDir       = "";
   m_stateFile       = "";
   m_queueHead       = 0;
   m_queueTail       = 0;
   m_queueCount      = 0;
   m_processedCount  = 0;
   m_status          = CONN_DISCONNECTED;
   m_lastHeartbeat   = 0;
   m_lastPoll        = 0;
   m_logger          = NULL;
   m_totalReceived   = 0;
   m_totalSkipped    = 0;
  }

//+------------------------------------------------------------------+
//| Initialise receiver for a given master/follower pair             |
//+------------------------------------------------------------------+
bool CSignalReceiver::Init(CLogger *logger, string masterId, string followerId)
  {
   m_logger     = logger;
   m_masterId   = masterId;
   m_followerId = followerId;
   m_signalDir  = CT_SIGNAL_DIR;

   m_stateFile = CT_STATE_DIR + CT_STATE_PREFIX +
                 followerId + "_" + masterId + ".txt";

   // Pre-allocate the processed-ID ring buffer (200 slots).
   ArrayResize(m_processedIds, 200);

   // Load previously processed IDs so we survive EA restarts without
   // re-executing signals that were already acted on.
   LoadProcessedIds();

   // Allocate the signal queue.
   ArrayResize(m_queue, CT_MAX_QUEUE_SIZE);
   m_queueHead  = 0;
   m_queueTail  = 0;
   m_queueCount = 0;

   if(m_logger != NULL)
      m_logger.Info("SignalReceiver initialized — master=" + masterId +
                    " follower=" + followerId);

   return true;
  }

//+------------------------------------------------------------------+
//| Poll for new signals.  Call from the EA's OnTimer handler.       |
//+------------------------------------------------------------------+
void CSignalReceiver::Poll()
  {
   CheckHeartbeat();
   ScanSignalFiles();
   m_lastPoll = TimeCurrent();
  }

//+------------------------------------------------------------------+
//| Read the master heartbeat file and update connection status      |
//+------------------------------------------------------------------+
void CSignalReceiver::CheckHeartbeat()
  {
   string hbPath = m_signalDir + CT_HEARTBEAT_PREFIX + m_masterId + ".txt";

   int handle = FileOpen(hbPath, FILE_READ | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);
   if(handle == INVALID_HANDLE)
     {
      // File not found — check whether we have exceeded the disconnect threshold.
      if(m_lastHeartbeat > 0 &&
         (TimeCurrent() - m_lastHeartbeat) > CT_HEARTBEAT_TIMEOUT)
        {
         SetStatus(CONN_DISCONNECTED);
        }
      else if(m_lastHeartbeat == 0)
        {
         // We have never seen a heartbeat from this master at all.
         SetStatus(CONN_DISCONNECTED);
        }
      return;
     }

   // The heartbeat file contains a single Unix timestamp string.
   string content = FileReadString(handle, 20);
   FileClose(handle);

   datetime hbTime = (datetime)StringToInteger(content);

   // Reject obviously invalid values (e.g. empty file, corrupt content).
   if(hbTime <= 0)
     {
      SetStatus(CONN_DEGRADED);
      return;
     }

   m_lastHeartbeat = hbTime;

   int age = (int)(TimeCurrent() - hbTime);

   if(age > CT_HEARTBEAT_TIMEOUT)
     {
      ENUM_CONNECTION_STATUS prevStatus = m_status;
      SetStatus(CONN_DISCONNECTED);

      // Escalate to Alert and push notification on first transition into
      // disconnected state so the trader is informed immediately.
      if(prevStatus != CONN_DISCONNECTED)
        {
         string msg = "CopyTrading: master " + m_masterId +
                      " heartbeat timeout (" + IntegerToString(age) + "s)";
         Alert(msg);
         SendNotification(msg);
        }
     }
   else if(age > CT_HEARTBEAT_SECS * 3)
     {
      // Heartbeat is present but lagging — mark as degraded.
      SetStatus(CONN_DEGRADED);
     }
   else
     {
      SetStatus(CONN_CONNECTED);
     }
  }

//+------------------------------------------------------------------+
//| Scan the signal directory for new signal files from the master   |
//+------------------------------------------------------------------+
void CSignalReceiver::ScanSignalFiles()
  {
   string searchPattern = m_signalDir + CT_SIGNAL_PREFIX + m_masterId + "_*.json";
   string foundName     = "";

   long findHandle = FileFindFirst(searchPattern, foundName, FILE_COMMON);
   if(findHandle == INVALID_HANDLE)
      return;

   do
     {
      ProcessSignalFile(foundName);
     }
   while(FileFindNext(findHandle, foundName));

   FileFindClose(findHandle);
  }

//+------------------------------------------------------------------+
//| Read, parse, validate, and enqueue a single signal file          |
//+------------------------------------------------------------------+
void CSignalReceiver::ProcessSignalFile(string filename)
  {
   // Extract the signal ID from the filename so we can check for duplicates
   // before incurring the cost of opening and reading the file.
   string signalId = ExtractSignalId(filename);
   if(signalId == "")
     {
      if(m_logger != NULL)
         m_logger.Warn("ProcessSignalFile: could not extract signalId from " + filename);
      return;
     }

   // Skip files we have already processed.
   if(IsAlreadyProcessed(signalId))
      return;

   string fullPath = m_signalDir + filename;

   int handle = FileOpen(fullPath, FILE_READ | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);
   if(handle == INVALID_HANDLE)
     {
      if(m_logger != NULL)
         m_logger.Warn("ProcessSignalFile: cannot open " + filename +
                       " error=" + IntegerToString(GetLastError()));
      return;
     }

   // Read the entire file contents.
   string json = "";
   while(!FileIsEnding(handle))
      json += FileReadString(handle);

   FileClose(handle);

   if(StringLen(json) == 0)
     {
      if(m_logger != NULL)
         m_logger.Warn("ProcessSignalFile: empty file " + filename);
      return;
     }

   // Deserialise the signal from JSON.
   CSignal sig;
   if(!sig.FromJSON(json))
     {
      if(m_logger != NULL)
         m_logger.Error("ProcessSignalFile: JSON parse failed for " + filename);
      return;
     }

   // Validate required fields.
   if(!sig.Validate())
     {
      if(m_logger != NULL)
         m_logger.Error("ProcessSignalFile: signal validation failed for " + signalId);
      return;
     }

   // Stale market-order signals must not be executed.
   if(sig.IsStale() && sig.type == SIGNAL_MARKET_ORDER)
     {
      if(m_logger != NULL)
         m_logger.Warn("ProcessSignalFile: skipping stale market-order signal " + signalId +
                       " age=" + IntegerToString((int)(TimeCurrent() - sig.timestamp)) + "s");
      MarkProcessed(signalId);
      m_totalSkipped++;
      return;
     }

   EnqueueSignal(sig);
   MarkProcessed(signalId);
   m_totalReceived++;

   if(m_logger != NULL)
      m_logger.Info("ProcessSignalFile: enqueued signal " + signalId +
                    " type=" + IntegerToString((int)sig.type) +
                    " symbol=" + sig.symbol);
  }

//+------------------------------------------------------------------+
//| Add a signal to the tail of the circular FIFO queue             |
//+------------------------------------------------------------------+
void CSignalReceiver::EnqueueSignal(const CSignal &signal)
  {
   if(m_queueCount >= CT_MAX_QUEUE_SIZE)
     {
      if(m_logger != NULL)
         m_logger.Warn("EnqueueSignal: queue overflow — dropping signal " + signal.signalId);
      m_totalSkipped++;
      return;
     }

   m_queue[m_queueTail] = signal;
   m_queueTail          = (m_queueTail + 1) % CT_MAX_QUEUE_SIZE;
   m_queueCount++;
  }

//+------------------------------------------------------------------+
//| Remove and return the oldest signal from the head of the queue   |
//| Returns false when the queue is empty.                           |
//+------------------------------------------------------------------+
bool CSignalReceiver::DequeueSignal(CSignal &signal)
  {
   if(m_queueCount == 0)
      return false;

   signal      = m_queue[m_queueHead];
   m_queueHead = (m_queueHead + 1) % CT_MAX_QUEUE_SIZE;
   m_queueCount--;

   return true;
  }

//+------------------------------------------------------------------+
//| Linear search in the processed-ID ring buffer                    |
//+------------------------------------------------------------------+
bool CSignalReceiver::IsAlreadyProcessed(string signalId) const
  {
   int slots = MathMin(m_processedCount, 200);
   for(int i = 0; i < slots; i++)
     {
      if(m_processedIds[i] == signalId)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Mark a signal ID as processed and persist it to the state file   |
//+------------------------------------------------------------------+
void CSignalReceiver::MarkProcessed(string signalId)
  {
   // Write into the ring buffer at position  (m_processedCount % 200).
   int slot = m_processedCount % 200;
   m_processedIds[slot] = signalId;
   m_processedCount++;

   // Append to the state file so we survive restarts.
   // We open with FILE_READ|FILE_WRITE to seek to the end for appending;
   // if the file does not exist yet we fall back to FILE_WRITE to create it.
   int handle = FileOpen(m_stateFile,
                         FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE)
     {
      FileSeek(handle, 0, SEEK_END);
      FileWriteString(handle, signalId + "\n");
      FileClose(handle);
     }
   else
     {
      handle = FileOpen(m_stateFile, FILE_WRITE | FILE_TXT | FILE_COMMON);
      if(handle != INVALID_HANDLE)
        {
         FileWriteString(handle, signalId + "\n");
         FileClose(handle);
        }
      else
        {
         if(m_logger != NULL)
            m_logger.Warn("MarkProcessed: cannot write state file " + m_stateFile +
                          " error=" + IntegerToString(GetLastError()));
        }
     }
  }

//+------------------------------------------------------------------+
//| Load previously processed signal IDs from the state file        |
//| Keeps only the last 200 entries to match the ring-buffer size.   |
//+------------------------------------------------------------------+
void CSignalReceiver::LoadProcessedIds()
  {
   int handle = FileOpen(m_stateFile,
                         FILE_READ | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);
   if(handle == INVALID_HANDLE)
      return;   // State file does not exist yet — that is normal on first run.

   // Read all lines into a temporary dynamic array first so we can
   // retain only the last 200.
   string allIds[];
   int    count = 0;
   ArrayResize(allIds, 1000);

   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      // FileReadString in TXT mode reads up to the newline delimiter.
      StringTrimRight(line);
      StringTrimLeft(line);
      if(StringLen(line) == 0)
         continue;

      if(count >= ArraySize(allIds))
         ArrayResize(allIds, count + 500);

      allIds[count] = line;
      count++;
     }

   FileClose(handle);

   // Copy the last 200 into the ring buffer.
   int start = MathMax(0, count - 200);
   m_processedCount = 0;

   for(int i = start; i < count; i++)
     {
      m_processedIds[m_processedCount % 200] = allIds[i];
      m_processedCount++;
     }

   if(m_logger != NULL)
      m_logger.Debug("LoadProcessedIds: loaded " + IntegerToString(m_processedCount) +
                     " processed signal IDs from state file");
  }

//+------------------------------------------------------------------+
//| Update connection status, logging on any state transition        |
//+------------------------------------------------------------------+
void CSignalReceiver::SetStatus(ENUM_CONNECTION_STATUS status)
  {
   if(status == m_status)
      return;

   if(m_logger != NULL)
      m_logger.Info("Connection status change: " + GetStatusString() +
                    " -> " + EnumToString(status) +
                    " master=" + m_masterId);

   m_status = status;
  }

//+------------------------------------------------------------------+
//| Return a human-readable description of the current status        |
//+------------------------------------------------------------------+
string CSignalReceiver::GetStatusString() const
  {
   switch(m_status)
     {
      case CONN_CONNECTED:    return "CONNECTED";
      case CONN_DEGRADED:     return "DEGRADED";
      case CONN_RECONNECTING: return "RECONNECTING";
      case CONN_DISCONNECTED: return "DISCONNECTED";
      case CONN_ERROR:        return "ERROR";
      default:                return "UNKNOWN";
     }
  }

//+------------------------------------------------------------------+
//| Extract the signal ID from a signal filename.                    |
//| Filename format: signal_<MASTERID>_<SIGNALID>.json               |
//| The SIGNALID is the segment between the last "_" and ".json".    |
//+------------------------------------------------------------------+
string CSignalReceiver::ExtractSignalId(const string &filename) const
  {
   // Strip the ".json" suffix first.
   int dotPos = StringFind(filename, ".json");
   if(dotPos < 0)
      return "";

   string withoutExt = StringSubstr(filename, 0, dotPos);

   // Find the last underscore — everything after it is the signal ID.
   int lastUnderscore = -1;
   int len            = StringLen(withoutExt);

   for(int i = len - 1; i >= 0; i--)
     {
      if(StringSubstr(withoutExt, i, 1) == "_")
        {
         lastUnderscore = i;
         break;
        }
     }

   if(lastUnderscore < 0 || lastUnderscore >= len - 1)
      return "";   // No underscore found or it is the very last character.

   return StringSubstr(withoutExt, lastUnderscore + 1);
  }
//+------------------------------------------------------------------+
