//+------------------------------------------------------------------+
//|                                                       Logger.mqh |
//|                         Loss Recovery Strategy - Event Logger     |
//+------------------------------------------------------------------+
#ifndef __LOGGER_MQH__
#define __LOGGER_MQH__

#include "Defines.mqh"
#include "Utils.mqh"

//+------------------------------------------------------------------+
//| CLogger - Event logging to CSV file and Experts tab               |
//+------------------------------------------------------------------+
class CLogger
{
private:
   string m_session_id;
   string m_log_path;
   bool   m_initialized;

public:
   CLogger();
   ~CLogger();

   bool   Init(string session_id = "");
   void   SetSessionID(string session_id) { m_session_id = session_id; }
   void   Log(ENUM_LOG_EVENT event_type, string details);
   void   LogTrade(ENUM_LOG_EVENT event_type, ulong ticket, double volume,
                   double price, string details);

private:
   void   WriteToFile(string line);
   void   EnsureHeader();
};

//+------------------------------------------------------------------+
CLogger::CLogger()
{
   m_session_id  = "";
   m_log_path    = RECOVERY_FOLDER + "\\" + LOG_FILENAME;
   m_initialized = false;
}

//+------------------------------------------------------------------+
CLogger::~CLogger()
{
}

//+------------------------------------------------------------------+
bool CLogger::Init(string session_id)
{
   m_session_id = session_id;

   // Ensure folder exists
   if(!FolderCreate(RECOVERY_FOLDER))
   {
      int err = GetLastError();
      if(err != 5004) // 5004 = already exists
      {
         Print("[Logger] Failed to create folder: ", RECOVERY_FOLDER, " error=", err);
         return false;
      }
   }

   EnsureHeader();
   m_initialized = true;
   return true;
}

//+------------------------------------------------------------------+
void CLogger::EnsureHeader()
{
   // Check if file exists and has content
   int handle = FileOpen(m_log_path, FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
   {
      // File doesn't exist, create with header
      handle = FileOpen(m_log_path, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(handle != INVALID_HANDLE)
      {
         FileWriteString(handle, "datetime,event_type,session_id,ticket,volume,price,details\n");
         FileClose(handle);
      }
      return;
   }

   // File exists, check if it has content
   ulong size = FileSize(handle);
   FileClose(handle);

   if(size == 0)
   {
      handle = FileOpen(m_log_path, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(handle != INVALID_HANDLE)
      {
         FileWriteString(handle, "datetime,event_type,session_id,ticket,volume,price,details\n");
         FileClose(handle);
      }
   }
}

//+------------------------------------------------------------------+
void CLogger::Log(ENUM_LOG_EVENT event_type, string details)
{
   string event_str = LogEventToString(event_type);
   string time_str  = FormatDateTime(TimeCurrent());

   // Print to Experts tab
   Print("[LossRecovery][", event_str, "] ", details);

   // Write to CSV
   string line = StringFormat("%s,%s,%s,0,0.0,0.0,%s\n",
                              time_str, event_str, m_session_id, details);
   WriteToFile(line);
}

//+------------------------------------------------------------------+
void CLogger::LogTrade(ENUM_LOG_EVENT event_type, ulong ticket, double volume,
                       double price, string details)
{
   string event_str = LogEventToString(event_type);
   string time_str  = FormatDateTime(TimeCurrent());

   // Print to Experts tab
   Print("[LossRecovery][", event_str, "] ticket=", ticket,
         " vol=", DoubleToString(volume, 2),
         " price=", DoubleToString(price, 5),
         " ", details);

   // Write to CSV
   string line = StringFormat("%s,%s,%s,%d,%.2f,%.5f,%s\n",
                              time_str, event_str, m_session_id,
                              ticket, volume, price, details);
   WriteToFile(line);
}

//+------------------------------------------------------------------+
void CLogger::WriteToFile(string line)
{
   int handle = FileOpen(m_log_path, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
   {
      Print("[Logger] Failed to open log file: ", m_log_path,
            " error=", GetLastError());
      return;
   }

   // Seek to end
   FileSeek(handle, 0, SEEK_END);
   FileWriteString(handle, line);
   FileClose(handle);
}

#endif // __LOGGER_MQH__
