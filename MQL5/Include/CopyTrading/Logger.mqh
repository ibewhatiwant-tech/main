//+------------------------------------------------------------------+
//| CopyTrading/Logger.mqh                                           |
//| Structured leveled logging system                                |
//+------------------------------------------------------------------+
#ifndef COPYTRADING_LOGGER_MQH
#define COPYTRADING_LOGGER_MQH
#include "Defines.mqh"

class CLogger
  {
private:
   ENUM_LOG_LEVEL    m_minLevel;
   string            m_component;
   string            m_logPath;        // Full file path within MQL5/Files
   int               m_fileHandle;
   datetime          m_currentDate;
   long              m_fileSizeBytes;
   bool              m_initialized;

   string            LevelToString(ENUM_LOG_LEVEL level) const;
   string            FormatTimestamp(datetime dt) const;
   void              WriteToFile(const string &line);
   void              OpenLogFile();
   void              CloseLogFile();
   bool              ShouldRotate();
   void              Rotate();
   string            BuildLogPath(datetime dt) const;

public:
                     CLogger();
                    ~CLogger();
   bool              Init(string component, ENUM_LOG_LEVEL minLevel=LOG_INFO);
   void              Deinit();
   void              Log(ENUM_LOG_LEVEL level, string message, string context="");
   void              Trace(string msg, string ctx="");
   void              Debug(string msg, string ctx="");
   void              Info(string msg, string ctx="");
   void              Warn(string msg, string ctx="");
   void              Error(string msg, string ctx="");
   void              Fatal(string msg, string ctx="");
   void              SetMinLevel(ENUM_LOG_LEVEL level);
   ENUM_LOG_LEVEL    GetMinLevel() const { return m_minLevel; }
  };

//+------------------------------------------------------------------+
//| Constructor                                                      |
//+------------------------------------------------------------------+
CLogger::CLogger()
  {
   m_minLevel      = LOG_INFO;
   m_component     = "";
   m_logPath       = "";
   m_fileHandle    = INVALID_HANDLE;
   m_currentDate   = 0;
   m_fileSizeBytes = 0;
   m_initialized   = false;
  }

//+------------------------------------------------------------------+
//| Destructor — ensure file handle is released                      |
//+------------------------------------------------------------------+
CLogger::~CLogger()
  {
   Deinit();
  }

//+------------------------------------------------------------------+
//| Convert level enum to fixed-width string label                   |
//+------------------------------------------------------------------+
string CLogger::LevelToString(ENUM_LOG_LEVEL level) const
  {
   switch(level)
     {
      case LOG_TRACE: return "TRACE";
      case LOG_DEBUG: return "DEBUG";
      case LOG_INFO:  return "INFO ";
      case LOG_WARN:  return "WARN ";
      case LOG_ERROR: return "ERROR";
      case LOG_FATAL: return "FATAL";
      default:        return "?????";
     }
  }

//+------------------------------------------------------------------+
//| Format a datetime as  YYYY-MM-DD HH:MM:SS                        |
//+------------------------------------------------------------------+
string CLogger::FormatTimestamp(datetime dt) const
  {
   // TimeToString returns "YYYY.MM.DD HH:MM:SS" — replace dots with dashes
   string s = TimeToString(dt, TIME_DATE | TIME_SECONDS);
   StringReplace(s, ".", "-");
   return s;
  }

//+------------------------------------------------------------------+
//| Build the log file path for a given date                         |
//| Result:  CT_LOG_DIR + component + "_" + YYYY-MM-DD + ".log"      |
//+------------------------------------------------------------------+
string CLogger::BuildLogPath(datetime dt) const
  {
   // TimeToString with TIME_DATE gives "YYYY.MM.DD"
   string dateStr = TimeToString(dt, TIME_DATE);
   StringReplace(dateStr, ".", "-");          // "YYYY-MM-DD"
   return CT_LOG_DIR + m_component + "_" + dateStr + ".log";
  }

//+------------------------------------------------------------------+
//| Open (or re-open) the log file, seeking to end for appending     |
//+------------------------------------------------------------------+
void CLogger::OpenLogFile()
  {
   CloseLogFile();

   m_logPath = BuildLogPath(m_currentDate);

   // Attempt to open existing file for read+write so we can seek to end
   m_fileHandle = FileOpen(m_logPath,
                           FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);

   if(m_fileHandle != INVALID_HANDLE)
     {
      // Seek to end to append
      FileSeek(m_fileHandle, 0, SEEK_END);
      m_fileSizeBytes = (long)FileTell(m_fileHandle);
     }
   else
     {
      // File does not exist yet — create it
      m_fileHandle = FileOpen(m_logPath,
                              FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);
      m_fileSizeBytes = 0;
     }

   if(m_fileHandle == INVALID_HANDLE)
      Print("CLogger::OpenLogFile — failed to open log file: ", m_logPath,
            " error: ", GetLastError());
  }

//+------------------------------------------------------------------+
//| Close the current log file handle                                |
//+------------------------------------------------------------------+
void CLogger::CloseLogFile()
  {
   if(m_fileHandle != INVALID_HANDLE)
     {
      FileClose(m_fileHandle);
      m_fileHandle = INVALID_HANDLE;
     }
  }

//+------------------------------------------------------------------+
//| Decide whether rotation is needed                                |
//+------------------------------------------------------------------+
bool CLogger::ShouldRotate()
  {
   // Day changed?
   datetime now = TimeCurrent();
   datetime nowDate = (datetime)(now - (now % 86400));   // floor to day boundary
   datetime curDate = (datetime)(m_currentDate - (m_currentDate % 86400));
   if(nowDate > curDate)
      return true;

   // Size limit exceeded?
   long maxBytes = (long)CT_LOG_MAX_SIZE_MB * 1024 * 1024;
   if(m_fileSizeBytes >= maxBytes)
      return true;

   return false;
  }

//+------------------------------------------------------------------+
//| Rotate: update current date and open a fresh log file            |
//+------------------------------------------------------------------+
void CLogger::Rotate()
  {
   m_currentDate = TimeCurrent();
   OpenLogFile();
  }

//+------------------------------------------------------------------+
//| Write a single line to the log file                              |
//+------------------------------------------------------------------+
void CLogger::WriteToFile(const string &line)
  {
   if(m_fileHandle == INVALID_HANDLE)
      return;

   FileWriteString(m_fileHandle, line + "\n");
   // Flush is implicit in MQL5 on each FileWriteString for TXT mode,
   // but we track the byte count ourselves for rotation decisions.
   m_fileSizeBytes += StringLen(line) + 1;
  }

//+------------------------------------------------------------------+
//| Initialise the logger                                            |
//+------------------------------------------------------------------+
bool CLogger::Init(string component, ENUM_LOG_LEVEL minLevel=LOG_INFO)
  {
   if(m_initialized)
      Deinit();

   m_component   = component;
   m_minLevel    = minLevel;
   m_currentDate = TimeCurrent();

   OpenLogFile();

   if(m_fileHandle == INVALID_HANDLE)
     {
      Print("CLogger::Init — could not open log file for component: ", component);
      return false;
     }

   m_initialized = true;

   // Write a startup banner so the log file has a visible session boundary
   string banner = "=== Logger started for [" + component + "] at " +
                   FormatTimestamp(m_currentDate) + " ===";
   WriteToFile(banner);

   return true;
  }

//+------------------------------------------------------------------+
//| Shut down logger gracefully                                      |
//+------------------------------------------------------------------+
void CLogger::Deinit()
  {
   if(m_initialized)
     {
      string banner = "=== Logger stopped for [" + m_component + "] at " +
                      FormatTimestamp(TimeCurrent()) + " ===";
      WriteToFile(banner);
     }
   CloseLogFile();
   m_initialized   = false;
   m_fileSizeBytes = 0;
  }

//+------------------------------------------------------------------+
//| Core log method                                                  |
//+------------------------------------------------------------------+
void CLogger::Log(ENUM_LOG_LEVEL level, string message, string context="")
  {
   if(level < m_minLevel)
      return;

   if(!m_initialized)
      return;

   // Check rotation before writing
   if(ShouldRotate())
      Rotate();

   datetime now = TimeCurrent();
   string ts    = FormatTimestamp(now);
   string lvl   = LevelToString(level);

   // Format: [2025-12-30 10:30:45] [INFO ] [ComponentName] Message {context}
   string line = "[" + ts + "] [" + lvl + "] [" + m_component + "] " + message;
   if(context != "")
      line += " {" + context + "}";

   WriteToFile(line);

   // Mirror ERROR and FATAL to the MT5 Experts journal
   if(level >= LOG_ERROR)
      Print(line);
  }

//+------------------------------------------------------------------+
//| Convenience wrappers                                             |
//+------------------------------------------------------------------+
void CLogger::Trace(string msg, string ctx="")
  {
   Log(LOG_TRACE, msg, ctx);
  }

void CLogger::Debug(string msg, string ctx="")
  {
   Log(LOG_DEBUG, msg, ctx);
  }

void CLogger::Info(string msg, string ctx="")
  {
   Log(LOG_INFO, msg, ctx);
  }

void CLogger::Warn(string msg, string ctx="")
  {
   Log(LOG_WARN, msg, ctx);
  }

void CLogger::Error(string msg, string ctx="")
  {
   Log(LOG_ERROR, msg, ctx);
  }

void CLogger::Fatal(string msg, string ctx="")
  {
   Log(LOG_FATAL, msg, ctx);
  }

//+------------------------------------------------------------------+
//| Change the minimum log level at runtime                          |
//+------------------------------------------------------------------+
void CLogger::SetMinLevel(ENUM_LOG_LEVEL level)
  {
   m_minLevel = level;
  }
#endif // COPYTRADING_LOGGER_MQH
