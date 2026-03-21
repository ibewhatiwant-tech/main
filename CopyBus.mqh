#ifndef __COPY_BUS_MQH__
#define __COPY_BUS_MQH__

class CSignalBusMaster
  {
private:
   string            m_prefix;
   ulong             m_cleanupCursor;
   enum { MAX_SIGNAL_BYTES=1536 };

   string U64ToString(const ulong v) const
     {
      return(StringFormat("%I64u",v));
     }

   string SeqKey() const
     {
      return(m_prefix+"_SEQ");
     }

   string SigKey(const ulong seq) const
     {
      return(m_prefix+"_SIG_"+U64ToString(seq));
     }

   string ChunkKey(const ulong seq,const int idx) const
     {
      return(SigKey(seq)+"_C_"+IntegerToString(idx));
     }

   bool WriteSignal(const ulong seq,const string payload)
     {
      int len=StringLen(payload);
      if(len<0 || len>MAX_SIGNAL_BYTES)
         return(false);

      int chunkCount=(len+5)/6;
      string keyHeader=SigKey(seq);
      if(!GlobalVariableSet(keyHeader,(double)len))
         return(false);

      for(int i=0;i<chunkCount;i++)
        {
         ulong packed=0;
         for(int j=0;j<6;j++)
           {
            int pos=i*6+j;
            if(pos>=len)
               break;
            int c=(int)StringGetCharacter(payload,pos);
            packed|=((ulong)(c & 0xFF) << (8*j));
           }

         if(!GlobalVariableSet(ChunkKey(seq,i),(double)packed))
            return(false);
        }
      return(true);
     }

   bool DeleteSignal(const ulong seq)
     {
      string keyHeader=SigKey(seq);
      int len=0;
      if(GlobalVariableCheck(keyHeader))
         len=(int)MathRound(GlobalVariableGet(keyHeader));

      if(len<0)
         len=0;
      if(len>MAX_SIGNAL_BYTES)
         len=MAX_SIGNAL_BYTES;

      int chunkCount=(len+5)/6;
      for(int i=0;i<chunkCount;i++)
        {
         string ck=ChunkKey(seq,i);
         if(GlobalVariableCheck(ck))
            GlobalVariableDel(ck);
        }

      if(GlobalVariableCheck(keyHeader))
         GlobalVariableDel(keyHeader);
      return(true);
     }

public:
   bool Init(const string prefix)
     {
      m_prefix=prefix;
      m_cleanupCursor=1;
      return(StringLen(m_prefix)>0);
     }

   bool Publish(const string serializedSignal,ulong &outSeq)
     {
      outSeq=0;
      if(StringLen(m_prefix)<=0)
         return(false);

      string keySeq=SeqKey();
      ulong currentSeq=0;
      if(GlobalVariableCheck(keySeq))
         currentSeq=(ulong)MathRound(GlobalVariableGet(keySeq));

      ulong nextSeq=currentSeq+1;
      if(!WriteSignal(nextSeq,serializedSignal))
         return(false);

      if(!GlobalVariableSet(keySeq,(double)nextSeq))
         return(false);

      outSeq=nextSeq;
      return(true);
     }

   bool CleanupOld(ulong keepFromSeq,int maxToDeletePerCall)
     {
      if(maxToDeletePerCall<=0)
         return(false);

      if(m_cleanupCursor==0)
         m_cleanupCursor=1;

      int deleted=0;
      while(m_cleanupCursor<keepFromSeq && deleted<maxToDeletePerCall)
        {
         DeleteSignal(m_cleanupCursor);
         m_cleanupCursor++;
         deleted++;
        }
      return(true);
     }
  };

class CSignalBusFollower
  {
private:
   string            m_prefix;
   enum { MAX_SIGNAL_BYTES=1536 };

   string U64ToString(const ulong v) const
     {
      return(StringFormat("%I64u",v));
     }

   string SeqKey() const
     {
      return(m_prefix+"_SEQ");
     }

   string FollowerSeqKey() const
     {
      return(m_prefix+"_FSEQ");
     }

   string SigKey(const ulong seq) const
     {
      return(m_prefix+"_SIG_"+U64ToString(seq));
     }

   string ChunkKey(const ulong seq,const int idx) const
     {
      return(SigKey(seq)+"_C_"+IntegerToString(idx));
     }

   bool ReadSignal(const ulong seq,string &payload) const
     {
      payload="";
      string keyHeader=SigKey(seq);
      if(!GlobalVariableCheck(keyHeader))
         return(false);

      int len=(int)MathRound(GlobalVariableGet(keyHeader));
      if(len<=0 || len>MAX_SIGNAL_BYTES)
         return(false);

      int chunkCount=(len+5)/6;
      string out="";
      int written=0;

      for(int i=0;i<chunkCount;i++)
        {
         string ck=ChunkKey(seq,i);
         if(!GlobalVariableCheck(ck))
            return(false);

         ulong packed=(ulong)MathRound(GlobalVariableGet(ck));
         for(int j=0;j<6 && written<len;j++)
           {
            int c=(int)((packed >> (8*j)) & 0xFF);
            out+=CharToString((ushort)c);
            written++;
           }
        }

      payload=out;
      return(true);
     }

public:
   bool Init(const string prefix)
     {
      m_prefix=prefix;
      return(StringLen(m_prefix)>0);
     }

   ulong GetLastSeq()
     {
      string keySeq=SeqKey();
      if(!GlobalVariableCheck(keySeq))
         return(0);
      return((ulong)MathRound(GlobalVariableGet(keySeq)));
     }

   bool SetLastSeq(ulong seq)
     {
      return(GlobalVariableSet(FollowerSeqKey(),(double)seq));
     }

   int FetchNew(string &buffer[],ulong &fromSeq,ulong &toSeq,int maxCount)
     {
      ArrayResize(buffer,0);
      toSeq=fromSeq;

      if(maxCount<=0)
         return(0);

      ulong currentSeq=GetLastSeq();
      if(currentSeq<=fromSeq)
        {
         toSeq=currentSeq;
         return(0);
        }

      ulong startSeq=fromSeq+1;
      ulong upperSeq=currentSeq;
      ulong maxUpper=startSeq+(ulong)maxCount-1;
      if(upperSeq>maxUpper)
         upperSeq=maxUpper;

      toSeq=upperSeq;
      int reserved=(int)(upperSeq-startSeq+1);
      ArrayResize(buffer,reserved);

      int count=0;
      ulong lastGood=fromSeq;

      for(ulong seq=startSeq;seq<=upperSeq;seq++)
        {
         string payload="";
         if(ReadSignal(seq,payload))
           {
            buffer[count]=payload;
            count++;
            lastGood=seq;
           }
        }

      ArrayResize(buffer,count);
      fromSeq=lastGood;
      return(count);
     }
  };

#endif // __COPY_BUS_MQH__
