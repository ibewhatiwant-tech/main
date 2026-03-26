//+------------------------------------------------------------------+
//|                                                  Persistence.mqh |
//|                         Loss Recovery Strategy - File Persistence |
//+------------------------------------------------------------------+
#ifndef __PERSISTENCE_MQH__
#define __PERSISTENCE_MQH__

#include "Defines.mqh"
#include "Utils.mqh"
#include "RecoverySession.mqh"
#include "Logger.mqh"

//+------------------------------------------------------------------+
//| CPersistence - Save/Load session state via JSON files             |
//+------------------------------------------------------------------+
class CPersistence
{
private:
   CLogger *m_logger;

   string  GetSessionFilePath(string session_id);
   string  GetTempFilePath(string session_id);

public:
   CPersistence();
   ~CPersistence();

   void   SetLogger(CLogger *logger) { m_logger = logger; }

   //--- Save/Load
   bool   SaveSession(CRecoverySession &session);
   bool   LoadSession(CRecoverySession &session, string session_id);
   bool   FindActiveSession(CRecoverySession &session);
   bool   ArchiveSession(string session_id);
   bool   DeleteSession(string session_id);

   //--- GlobalVariable helpers
   void   SetGlobalState(string session_id, ENUM_SESSION_STATE state);
   void   SetPauseFlag(bool pause);
   bool   GetPauseFlag();
   void   ClearGlobalVars();

   //--- Reconciliation
   bool   ReconcileSession(CRecoverySession &session);
};

//+------------------------------------------------------------------+
CPersistence::CPersistence()
{
   m_logger = NULL;
}

//+------------------------------------------------------------------+
CPersistence::~CPersistence()
{
}

//+------------------------------------------------------------------+
string CPersistence::GetSessionFilePath(string session_id)
{
   return RECOVERY_FOLDER + "\\" + SESSION_PREFIX + session_id + ".json";
}

//+------------------------------------------------------------------+
string CPersistence::GetTempFilePath(string session_id)
{
   return RECOVERY_FOLDER + "\\" + SESSION_PREFIX + session_id + TEMP_SUFFIX;
}

//+------------------------------------------------------------------+
//| Save session with atomic write (tmp -> rename)                    |
//+------------------------------------------------------------------+
bool CPersistence::SaveSession(CRecoverySession &session)
{
   // Ensure folder exists
   FolderCreate(RECOVERY_FOLDER);

   string json = session.ToJSON();
   string tmp_path  = GetTempFilePath(session.session_id);
   string file_path = GetSessionFilePath(session.session_id);

   // Write to temp file
   int handle = FileOpen(tmp_path, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
   {
      int err = GetLastError();
      if(m_logger != NULL)
         m_logger.Log(LOG_ERROR, "Failed to open temp file for write: " +
                      tmp_path + " err=" + IntegerToString(err));
      return false;
   }

   FileWriteString(handle, json);
   FileClose(handle);

   // Delete existing file if present
   if(FileIsExist(file_path))
      FileDelete(file_path);

   // Rename tmp to final (atomic operation)
   if(!FileMove(tmp_path, 0, file_path, FILE_REWRITE))
   {
      int err = GetLastError();
      // Fallback: try direct write if rename fails
      if(m_logger != NULL)
         m_logger.Log(LOG_ERROR, "FileMove failed, attempting direct write. err=" +
                      IntegerToString(err));

      handle = FileOpen(file_path, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(handle == INVALID_HANDLE)
      {
         if(m_logger != NULL)
            m_logger.Log(LOG_ERROR, "Direct write also failed for: " + file_path);
         return false;
      }
      FileWriteString(handle, json);
      FileClose(handle);

      // Clean up temp
      FileDelete(tmp_path);
   }

   // Update GlobalVariables
   SetGlobalState(session.session_id, session.state);

   return true;
}

//+------------------------------------------------------------------+
//| Load session from JSON file                                       |
//+------------------------------------------------------------------+
bool CPersistence::LoadSession(CRecoverySession &session, string session_id)
{
   string file_path = GetSessionFilePath(session_id);

   if(!FileIsExist(file_path))
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_INFO, "Session file not found: " + file_path);
      return false;
   }

   int handle = FileOpen(file_path, FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_ERROR, "Failed to open session file: " + file_path +
                      " err=" + IntegerToString(GetLastError()));
      return false;
   }

   // Read entire file
   string json = "";
   while(!FileIsEnding(handle))
   {
      json += FileReadString(handle);
   }
   FileClose(handle);

   if(StringLen(json) == 0)
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_ERROR, "Empty session file: " + file_path);
      return false;
   }

   return session.FromJSON(json);
}

//+------------------------------------------------------------------+
//| Find any active session in the recovery folder                    |
//+------------------------------------------------------------------+
bool CPersistence::FindActiveSession(CRecoverySession &session)
{
   // First check GlobalVariable for session ID
   if(GlobalVariableCheck(GV_SESSION_ID))
   {
      double gv_val = GlobalVariableGet(GV_SESSION_ID);
      // GV stores a numeric hash - we need to scan files instead
   }

   // Scan folder for session files
   string search_path = RECOVERY_FOLDER + "\\" + SESSION_PREFIX + "*.json";
   string filename;
   long search_handle = FileFindFirst(search_path, filename, 0);

   if(search_handle == INVALID_HANDLE)
      return false;

   do
   {
      // Extract session ID from filename
      string sid = filename;
      StringReplace(sid, SESSION_PREFIX, "");
      StringReplace(sid, ".json", "");

      CRecoverySession temp_session;
      if(LoadSession(temp_session, sid))
      {
         if(temp_session.IsActive())
         {
            session = temp_session;
            FileFindClose(search_handle);
            return true;
         }
      }
   }
   while(FileFindNext(search_handle, filename));

   FileFindClose(search_handle);
   return false;
}

//+------------------------------------------------------------------+
//| Archive a completed session (rename with _archived suffix)        |
//+------------------------------------------------------------------+
bool CPersistence::ArchiveSession(string session_id)
{
   string src = GetSessionFilePath(session_id);
   string dst = RECOVERY_FOLDER + "\\" + SESSION_PREFIX + session_id + "_archived.json";

   if(!FileIsExist(src))
      return false;

   if(FileIsExist(dst))
      FileDelete(dst);

   bool result = FileMove(src, 0, dst, FILE_REWRITE);

   if(!result)
   {
      // Fallback: copy content then delete original
      int src_handle = FileOpen(src, FILE_READ | FILE_TXT | FILE_ANSI);
      if(src_handle == INVALID_HANDLE) return false;

      string content = "";
      while(!FileIsEnding(src_handle))
         content += FileReadString(src_handle);
      FileClose(src_handle);

      int dst_handle = FileOpen(dst, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(dst_handle == INVALID_HANDLE) return false;

      FileWriteString(dst_handle, content);
      FileClose(dst_handle);

      FileDelete(src);
      result = true;
   }

   return result;
}

//+------------------------------------------------------------------+
bool CPersistence::DeleteSession(string session_id)
{
   string file_path = GetSessionFilePath(session_id);
   if(FileIsExist(file_path))
      return FileDelete(file_path);
   return true;
}

//+------------------------------------------------------------------+
//| GlobalVariable helpers                                            |
//+------------------------------------------------------------------+
void CPersistence::SetGlobalState(string session_id, ENUM_SESSION_STATE state)
{
   GlobalVariableSet(GV_STATE, (double)state);
   // Store a simple hash of session_id for quick check
   long hash = 0;
   for(int i = 0; i < StringLen(session_id); i++)
      hash = hash * 31 + StringGetCharacter(session_id, i);
   GlobalVariableSet(GV_SESSION_ID, (double)hash);
}

//+------------------------------------------------------------------+
void CPersistence::SetPauseFlag(bool pause)
{
   GlobalVariableSet(GV_PAUSE_TRADE, pause ? 1.0 : 0.0);
}

//+------------------------------------------------------------------+
bool CPersistence::GetPauseFlag()
{
   if(!GlobalVariableCheck(GV_PAUSE_TRADE))
      return false;
   return (GlobalVariableGet(GV_PAUSE_TRADE) > 0.5);
}

//+------------------------------------------------------------------+
void CPersistence::ClearGlobalVars()
{
   GlobalVariableDel(GV_SESSION_ID);
   GlobalVariableDel(GV_STATE);
   GlobalVariableDel(GV_PAUSE_TRADE);
   GlobalVariableDel(GV_FILE_LOCK);
}

//+------------------------------------------------------------------+
//| Reconcile session with live positions after restart                |
//+------------------------------------------------------------------+
bool CPersistence::ReconcileSession(CRecoverySession &session)
{
   bool changed = false;

   // Check losing position
   if(session.losing_position.ticket > 0)
   {
      if(!PositionSelectByTicket(session.losing_position.ticket))
      {
         if(m_logger != NULL)
            m_logger.Log(LOG_INFO, "Losing position #" +
                         IntegerToString(session.losing_position.ticket) +
                         " no longer exists - marking volume=0");
         session.losing_position.volume = 0.0;
         changed = true;
      }
      else
      {
         // Update current values
         session.losing_position.volume = PositionGetDouble(POSITION_VOLUME);
         session.losing_position.pnl = PositionGetDouble(POSITION_PROFIT) +
                                       PositionGetDouble(POSITION_SWAP);
      }
   }

   // Check hedge position
   if(session.hedge_position.ticket > 0)
   {
      if(!PositionSelectByTicket(session.hedge_position.ticket))
      {
         if(m_logger != NULL)
            m_logger.Log(LOG_INFO, "Hedge position #" +
                         IntegerToString(session.hedge_position.ticket) +
                         " no longer exists - marking volume=0");
         session.hedge_position.volume = 0.0;
         changed = true;
      }
      else
      {
         session.hedge_position.volume = PositionGetDouble(POSITION_VOLUME);
         session.hedge_position.pnl = PositionGetDouble(POSITION_PROFIT) +
                                      PositionGetDouble(POSITION_SWAP);
      }
   }

   // Check averaging orders
   for(int i = 0; i < ArraySize(session.averaging_orders); i++)
   {
      if(session.averaging_orders[i].is_closed)
         continue;

      if(session.averaging_orders[i].ticket > 0)
      {
         if(!PositionSelectByTicket(session.averaging_orders[i].ticket))
         {
            if(m_logger != NULL)
               m_logger.Log(LOG_INFO, "Averaging order #" +
                            IntegerToString(session.averaging_orders[i].ticket) +
                            " no longer exists - marking closed");
            session.averaging_orders[i].is_closed = true;
            changed = true;
         }
         else
         {
            session.averaging_orders[i].volume = PositionGetDouble(POSITION_VOLUME);
            session.averaging_orders[i].pnl = PositionGetDouble(POSITION_PROFIT) +
                                              PositionGetDouble(POSITION_SWAP);
         }
      }
   }

   // If losing position is gone and hedge is gone, session should be cleaned up
   if(session.losing_position.volume <= 0 && session.hedge_position.volume <= 0 &&
      session.GetActiveAveragingCount() == 0 && session.IsActive())
   {
      if(m_logger != NULL)
         m_logger.Log(LOG_INFO, "All positions closed externally - moving to CLEANUP");
      session.SetState(STATE_CLEANUP);
      changed = true;
   }

   return changed;
}

#endif // __PERSISTENCE_MQH__
