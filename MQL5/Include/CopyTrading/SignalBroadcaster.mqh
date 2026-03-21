//+------------------------------------------------------------------+
//| CopyTrading/SignalBroadcaster.mqh                                |
//| Broadcasts trade signals to followers via file system            |
//+------------------------------------------------------------------+
#pragma once
#include "Defines.mqh"
#include "Logger.mqh"
#include "Signal.mqh"

//+------------------------------------------------------------------+
//| CSignalBroadcaster                                               |
//| Writes trade signals to the shared file directory so that        |
//| follower EAs running on any terminal can pick them up.           |
//| Includes a heartbeat mechanism, a retry queue for failed writes, |
//| and periodic cleanup of stale signal files.                      |
//+------------------------------------------------------------------+
class CSignalBroadcaster
  {
private:
   string            m_masterId;           // Master's unique identifier
   string            m_signalDir;          // Signal directory path
   string            m_retryQueue[];       // Failed signal JSON strings for retry
   string            m_retryIds[];         // Corresponding signal IDs for retry entries
   int               m_retryCount;         // Number of entries in the retry queue
   datetime          m_lastHeartbeat;      // Time of last heartbeat write
   datetime          m_lastCleanup;        // Time of last file cleanup pass
   int               m_broadcastCount;     // Total signals successfully broadcast
   int               m_failCount;          // Total signals that failed to broadcast
   CLogger          *m_logger;             // Shared logger (not owned)

   //--- Private helpers
   bool              WriteSignalFile(string filename, string json, string signalId);
   void              SetGlobalVar(string signalId, string json);
   void              CleanupOldSignals();
   void              ProcessRetryQueue();

public:
                     CSignalBroadcaster();

   bool              Init(CLogger *logger, string masterId);
   bool              BroadcastSignal(const CSignal &signal);
   void              WriteHeartbeat();
   void              OnTimer();

   int               GetBroadcastCount() const { return m_broadcastCount; }
   int               GetFailCount()      const { return m_failCount;      }
   string            GetMasterId()       const { return m_masterId;       }
  };

//+------------------------------------------------------------------+
//| Constructor — zero-initialise all members                        |
//+------------------------------------------------------------------+
CSignalBroadcaster::CSignalBroadcaster()
  {
   m_masterId       = "";
   m_signalDir      = "";
   m_retryCount     = 0;
   m_lastHeartbeat  = 0;
   m_lastCleanup    = 0;
   m_broadcastCount = 0;
   m_failCount      = 0;
   m_logger         = NULL;

   ArrayResize(m_retryQueue, CT_MAX_RETRY_COUNT * 10);
   ArrayResize(m_retryIds,   CT_MAX_RETRY_COUNT * 10);
  }

//+------------------------------------------------------------------+
//| Initialise broadcaster for a given master account                |
//+------------------------------------------------------------------+
bool CSignalBroadcaster::Init(CLogger *logger, string masterId)
  {
   m_logger    = logger;
   m_masterId  = masterId;
   m_signalDir = CT_SIGNAL_DIR;

   if(m_logger != NULL)
      m_logger.Info("Broadcaster initialized for master: " + masterId);

   WriteHeartbeat();

   return true;
  }

//+------------------------------------------------------------------+
//| Broadcast a trade signal to all followers                        |
//| Writes the signal as a JSON file and sets a global variable      |
//| notification so same-terminal followers react immediately.       |
//+------------------------------------------------------------------+
bool CSignalBroadcaster::BroadcastSignal(const CSignal &signal)
  {
   string json     = signal.ToJSON();
   string filename = CT_SIGNAL_PREFIX + m_masterId + "_" + signal.signalId + ".json";

   bool ok = WriteSignalFile(filename, json, signal.signalId);

   // Notify same-terminal followers via global variable (timestamp only;
   // actual data is always read from the file).
   SetGlobalVar(signal.signalId, json);

   if(ok)
     {
      m_broadcastCount++;
      if(m_logger != NULL)
         m_logger.Info("Signal broadcast: " + signal.signalId +
                       " type=" + IntegerToString((int)signal.type) +
                       " symbol=" + signal.symbol +
                       " vol="   + DoubleToString(signal.volume, 2));
     }
   else
     {
      // Push to retry queue so OnTimer() can re-attempt the write.
      if(m_retryCount < ArraySize(m_retryQueue))
        {
         m_retryQueue[m_retryCount] = json;
         m_retryIds[m_retryCount]   = signal.signalId;
         m_retryCount++;
        }
      m_failCount++;

      if(m_logger != NULL)
         m_logger.Error("Signal broadcast failed, queued for retry: " + signal.signalId);

      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Write the signal JSON to a file in the common shared directory   |
//+------------------------------------------------------------------+
bool CSignalBroadcaster::WriteSignalFile(string filename, string json, string signalId)
  {
   string fullPath = m_signalDir + filename;

   int handle = FileOpen(fullPath, FILE_WRITE | FILE_TXT | FILE_COMMON, '\n');
   if(handle == INVALID_HANDLE)
     {
      if(m_logger != NULL)
         m_logger.Error("WriteSignalFile: FileOpen failed for " + fullPath +
                        " error=" + IntegerToString(GetLastError()),
                        signalId);
      return false;
     }

   FileWriteString(handle, json);
   FileClose(handle);

   return true;
  }

//+------------------------------------------------------------------+
//| Notify same-terminal followers that a new signal is available.   |
//| MQL5 GlobalVariableSet only stores doubles, so JSON cannot be    |
//| stored directly. File-based delivery is the primary mechanism;   |
//| the global variable simply carries a timestamp so a same-        |
//| terminal follower can trigger an immediate poll without waiting  |
//| for its next timer tick.                                         |
//| // Global variable method not used for JSON; file-based is primary |
//+------------------------------------------------------------------+
void CSignalBroadcaster::SetGlobalVar(string signalId, string json)
  {
   // Store only a timestamp to indicate that new signal data is available.
   GlobalVariableSet("CT_" + m_masterId + "_SIGNAL_TIME", (double)TimeCurrent());
  }

//+------------------------------------------------------------------+
//| Write / refresh the master heartbeat file                        |
//| Followers read this file to detect whether the master is alive.  |
//+------------------------------------------------------------------+
void CSignalBroadcaster::WriteHeartbeat()
  {
   string path = CT_SIGNAL_DIR + CT_HEARTBEAT_PREFIX + m_masterId + ".txt";

   int handle = FileOpen(path, FILE_WRITE | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE)
     {
      FileWriteString(handle, IntegerToString(TimeCurrent()));
      FileClose(handle);
     }
   else
     {
      if(m_logger != NULL)
         m_logger.Warn("WriteHeartbeat: could not write heartbeat file " + path +
                       " error=" + IntegerToString(GetLastError()));
     }

   m_lastHeartbeat = TimeCurrent();
  }

//+------------------------------------------------------------------+
//| Called periodically (from the EA's OnTimer handler).             |
//| Refreshes the heartbeat, triggers cleanup when due, and retries  |
//| any queued failed signals.                                       |
//+------------------------------------------------------------------+
void CSignalBroadcaster::OnTimer()
  {
   datetime now = TimeCurrent();

   if(now - m_lastHeartbeat >= CT_HEARTBEAT_SECS)
      WriteHeartbeat();

   if(now - m_lastCleanup >= CT_FILE_CLEANUP_SECS)
      CleanupOldSignals();

   ProcessRetryQueue();
  }

//+------------------------------------------------------------------+
//| Delete signal files belonging to this master that are older than |
//| CT_FILE_CLEANUP_SECS seconds.  The age is determined by reading  |
//| the "timestamp" field from the JSON payload inside each file,    |
//| because MQL5 does not expose file modification times.            |
//+------------------------------------------------------------------+
void CSignalBroadcaster::CleanupOldSignals()
  {
   string searchPath = m_signalDir + CT_SIGNAL_PREFIX + m_masterId + "_*.json";
   string foundName  = "";

   long findHandle = FileFindFirst(searchPath, foundName, FILE_COMMON);
   if(findHandle == INVALID_HANDLE)
     {
      m_lastCleanup = TimeCurrent();
      return;
     }

   datetime now = TimeCurrent();

   do
     {
      string fullPath = m_signalDir + foundName;

      // Open the file and read enough of the JSON to extract the timestamp field.
      int fh = FileOpen(fullPath, FILE_READ | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);
      if(fh == INVALID_HANDLE)
         continue;

      // Read at most 200 characters — the timestamp appears near the start of the JSON.
      string chunk = FileReadString(fh, 200);
      FileClose(fh);

      // Extract "timestamp":<value> from the chunk using a simple scan.
      string tsKey   = "\"timestamp\":";
      int    tsPos   = StringFind(chunk, tsKey);
      datetime sigTime = 0;

      if(tsPos >= 0)
        {
         int valStart = tsPos + StringLen(tsKey);
         // Collect digits
         string numStr = "";
         int    chunkLen = StringLen(chunk);
         for(int i = valStart; i < chunkLen; i++)
           {
            string ch = StringSubstr(chunk, i, 1);
            if(ch >= "0" && ch <= "9")
               numStr += ch;
            else
               break;
           }
         if(StringLen(numStr) > 0)
            sigTime = (datetime)StringToInteger(numStr);
        }

      // If we could not parse a timestamp, use 0 so the file is treated as
      // maximally old and gets cleaned up rather than lingering forever.
      if(sigTime == 0 || (now - sigTime) > CT_FILE_CLEANUP_SECS)
        {
         FileDelete(fullPath, FILE_COMMON);
         if(m_logger != NULL)
            m_logger.Debug("CleanupOldSignals: deleted " + foundName);
        }
     }
   while(FileFindNext(findHandle, foundName));

   FileFindClose(findHandle);

   m_lastCleanup = TimeCurrent();
  }

//+------------------------------------------------------------------+
//| Re-attempt writes for entries in the retry queue.               |
//| Entries that still fail after CT_MAX_RETRY_COUNT total attempts  |
//| are discarded to prevent unbounded queue growth.                 |
//+------------------------------------------------------------------+
void CSignalBroadcaster::ProcessRetryQueue()
  {
   if(m_retryCount == 0)
      return;

   int remaining = 0;

   // Temporary arrays to hold the survivors after this pass.
   string survivorQueue[];
   string survivorIds[];
   ArrayResize(survivorQueue, m_retryCount);
   ArrayResize(survivorIds,   m_retryCount);

   for(int i = 0; i < m_retryCount; i++)
     {
      string signalId = m_retryIds[i];
      string json     = m_retryQueue[i];

      // Re-derive the filename from the signal ID.
      string filename = CT_SIGNAL_PREFIX + m_masterId + "_" + signalId + ".json";

      bool ok = WriteSignalFile(filename, json, signalId);
      if(ok)
        {
         m_broadcastCount++;
         m_failCount--;   // Correct the fail count; the signal did eventually succeed.
         if(m_logger != NULL)
            m_logger.Info("ProcessRetryQueue: retry succeeded for signal " + signalId);
        }
      else
        {
         // Check how many times this has been tried already.
         // We encode the attempt count as a suffix on the retained ID:
         //   original ID  →  first failure stores it as-is (attempt 1 failed)
         //   second failure → "ID|2"
         //   third failure  → "ID|3" → discard after this pass
         int    pipePos   = StringFind(signalId, "|");
         int    attempts  = 1;
         string baseId    = signalId;

         if(pipePos >= 0)
           {
            baseId   = StringSubstr(signalId, 0, pipePos);
            attempts = (int)StringToInteger(StringSubstr(signalId, pipePos + 1));
           }

         attempts++;

         if(attempts <= CT_MAX_RETRY_COUNT)
           {
            // Keep it in the queue with updated attempt count.
            survivorIds[remaining]   = baseId + "|" + IntegerToString(attempts);
            survivorQueue[remaining] = json;
            remaining++;
           }
         else
           {
            if(m_logger != NULL)
               m_logger.Error("ProcessRetryQueue: discarding signal after " +
                              IntegerToString(CT_MAX_RETRY_COUNT) +
                              " failed attempts: " + baseId);
           }
        }
     }

   // Copy survivors back.
   m_retryCount = remaining;
   for(int i = 0; i < remaining; i++)
     {
      m_retryQueue[i] = survivorQueue[i];
      m_retryIds[i]   = survivorIds[i];
     }
  }
//+------------------------------------------------------------------+
