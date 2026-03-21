#ifndef __COPY_TYPES_MQH__
#define __COPY_TYPES_MQH__

enum TradeSignalType
  {
   SIGNAL_MARKET=0,
   SIGNAL_PENDING=1,
   SIGNAL_MODIFY=2,
   SIGNAL_CLOSE=3
  };

enum TradeAction
  {
   ACTION_BUY=0,
   ACTION_SELL=1,
   ACTION_BUY_LIMIT=2,
   ACTION_SELL_LIMIT=3,
   ACTION_BUY_STOP=4,
   ACTION_SELL_STOP=5
  };

struct CTradeSignal
  {
   string            signalId;
   string            masterId;
   datetime          timestamp;
   int               tradeType;
   int               action;
   string            symbol;
   double            volume;
   double            price;
   double            stopLoss;
   double            takeProfit;
   string            comment;
   long              magicNumber;
   ulong             orderTicket;
   int               slippage;
   datetime          expiration;
  };

static int g_signal_id_counter=0;
static bool g_signal_id_seeded=false;

int CopyHexNibble(const int c)
  {
   if(c>='0' && c<='9')
      return(c-'0');
   if(c>='A' && c<='F')
      return(c-'A'+10);
   if(c>='a' && c<='f')
      return(c-'a'+10);
   return(-1);
  }

string CopyEscapeField(const string src)
  {
   string out="";
   int len=StringLen(src);
   for(int i=0;i<len;i++)
     {
      int c=(int)StringGetCharacter(src,i);
      if(c=='%' || c=='|' || c=='\r' || c=='\n')
        {
         string hx=IntegerToString(c,16);
         StringToUpper(hx);
         if(StringLen(hx)<2)
            hx="0"+hx;
         out+="%"+hx;
        }
      else
        {
         out+=CharToString((ushort)c);
        }
     }
   return(out);
  }

string CopyUnescapeField(const string src)
  {
   string out="";
   int len=StringLen(src);
   for(int i=0;i<len;i++)
     {
      int c=(int)StringGetCharacter(src,i);
      if(c=='%' && i+2<len)
        {
         int h1=CopyHexNibble((int)StringGetCharacter(src,i+1));
         int h2=CopyHexNibble((int)StringGetCharacter(src,i+2));
         if(h1>=0 && h2>=0)
           {
            int v=h1*16+h2;
            out+=CharToString((ushort)v);
            i+=2;
            continue;
           }
        }
      out+=CharToString((ushort)c);
     }
   return(out);
  }

string GenerateSignalId(const string masterId="")
  {
   if(!g_signal_id_seeded)
     {
      MathSrand((int)(TimeLocal() ^ (datetime)GetTickCount()));
      g_signal_id_seeded=true;
     }

   g_signal_id_counter++;
   ulong micros=GetMicrosecondCount();
   int rnd=MathRand();
   return(StringFormat("%s_%I64d_%I64u_%d_%d",masterId,(long)TimeLocal(),micros,g_signal_id_counter,rnd));
  }

string TradeSignalToString(const CTradeSignal &sig)
  {
   string fields[15];
   fields[0]=CopyEscapeField(sig.signalId);
   fields[1]=CopyEscapeField(sig.masterId);
   fields[2]=LongToString((long)sig.timestamp);
   fields[3]=IntegerToString(sig.tradeType);
   fields[4]=IntegerToString(sig.action);
   fields[5]=CopyEscapeField(sig.symbol);
   fields[6]=DoubleToString(sig.volume,8);
   fields[7]=DoubleToString(sig.price,8);
   fields[8]=DoubleToString(sig.stopLoss,8);
   fields[9]=DoubleToString(sig.takeProfit,8);
   fields[10]=CopyEscapeField(sig.comment);
   fields[11]=LongToString(sig.magicNumber);
   fields[12]=StringFormat("%I64u",sig.orderTicket);
   fields[13]=IntegerToString(sig.slippage);
   fields[14]=LongToString((long)sig.expiration);

   string out=fields[0];
   for(int i=1;i<15;i++)
      out+="|"+fields[i];
   return(out);
  }

bool StringToTradeSignal(const string data,CTradeSignal &sig)
  {
   string parts[];
   int n=StringSplit(data,'|',parts);
   if(n!=15)
      return(false);

   sig.signalId=CopyUnescapeField(parts[0]);
   sig.masterId=CopyUnescapeField(parts[1]);
   sig.timestamp=(datetime)StringToInteger(parts[2]);
   sig.tradeType=(int)StringToInteger(parts[3]);
   sig.action=(int)StringToInteger(parts[4]);
   sig.symbol=CopyUnescapeField(parts[5]);
   sig.volume=StringToDouble(parts[6]);
   sig.price=StringToDouble(parts[7]);
   sig.stopLoss=StringToDouble(parts[8]);
   sig.takeProfit=StringToDouble(parts[9]);
   sig.comment=CopyUnescapeField(parts[10]);
   sig.magicNumber=(long)StringToInteger(parts[11]);
   sig.orderTicket=(ulong)StringToInteger(parts[12]);
   sig.slippage=(int)StringToInteger(parts[13]);
   sig.expiration=(datetime)StringToInteger(parts[14]);
   return(true);
  }

#endif // __COPY_TYPES_MQH__
