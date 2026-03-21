#property strict
#property version   "1.00"

#include "CopyTypes.mqh"
#include "CopyBus.mqh"

input string InpMasterId = "MASTER_1";
input string InpBusPrefix = "COPY";
input long   InpMagic = 123456;

CSignalBusMaster g_bus;
string g_masterId="";

int MapOrderTypeToAction(const ENUM_ORDER_TYPE orderType)
  {
   switch(orderType)
     {
      case ORDER_TYPE_BUY:          return(ACTION_BUY);
      case ORDER_TYPE_SELL:         return(ACTION_SELL);
      case ORDER_TYPE_BUY_LIMIT:    return(ACTION_BUY_LIMIT);
      case ORDER_TYPE_SELL_LIMIT:   return(ACTION_SELL_LIMIT);
      case ORDER_TYPE_BUY_STOP:
      case ORDER_TYPE_BUY_STOP_LIMIT:
         return(ACTION_BUY_STOP);
      case ORDER_TYPE_SELL_STOP:
      case ORDER_TYPE_SELL_STOP_LIMIT:
         return(ACTION_SELL_STOP);
      default:
         return(ACTION_BUY);
     }
  }

int MapDealTypeToAction(const ENUM_DEAL_TYPE dealType)
  {
   if(dealType==DEAL_TYPE_SELL)
      return(ACTION_SELL);
   return(ACTION_BUY);
  }

bool IsRelevantMagic(const long magic)
  {
   if(InpMagic==0)
      return(true);
   return(magic==InpMagic);
  }

bool PublishSignal(CTradeSignal &sig)
  {
   sig.signalId=GenerateSignalId(g_masterId);
   sig.masterId=g_masterId;
   sig.timestamp=TimeCurrent();

   string payload=TradeSignalToString(sig);
   ulong seq=0;
   if(!g_bus.Publish(payload,seq))
     {
      PrintFormat("[MASTER] Publish failed for signalId=%s",sig.signalId);
      return(false);
     }

   PrintFormat("[MASTER] Published seq=%I64u type=%d action=%d symbol=%s vol=%.2f",
               seq,sig.tradeType,sig.action,sig.symbol,sig.volume);
   return(true);
  }

int OnInit()
  {
   if(!g_bus.Init(InpBusPrefix))
      return(INIT_FAILED);

   g_masterId=InpMasterId;
   EventSetTimer(5);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTimer()
  {
   string seqKey=InpBusPrefix+"_SEQ";
   if(!GlobalVariableCheck(seqKey))
      return;

   ulong currentSeq=(ulong)MathRound(GlobalVariableGet(seqKey));
   ulong keepFromSeq=0;
   if(currentSeq>1000)
      keepFromSeq=currentSeq-1000+1;

   g_bus.CleanupOld(keepFromSeq,20);
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   CTradeSignal sig;
   sig.signalId="";
   sig.masterId=g_masterId;
   sig.timestamp=TimeCurrent();
   sig.tradeType=SIGNAL_MARKET;
   sig.action=ACTION_BUY;
   sig.symbol=trans.symbol;
   sig.volume=trans.volume;
   sig.price=trans.price;
   sig.stopLoss=trans.price_sl;
   sig.takeProfit=trans.price_tp;
   sig.comment="";
   sig.magicNumber=InpMagic;
   sig.orderTicket=trans.order;
   sig.slippage=(int)request.deviation;
   sig.expiration=0;

   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
     {
      if(!HistoryDealSelect(trans.deal))
         return;

      long magic=HistoryDealGetInteger(trans.deal,DEAL_MAGIC);
      if(!IsRelevantMagic(magic))
         return;

      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
      ENUM_DEAL_TYPE dealType=(ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal,DEAL_TYPE);

      sig.symbol=HistoryDealGetString(trans.deal,DEAL_SYMBOL);
      sig.volume=HistoryDealGetDouble(trans.deal,DEAL_VOLUME);
      sig.price=HistoryDealGetDouble(trans.deal,DEAL_PRICE);
      sig.stopLoss=HistoryDealGetDouble(trans.deal,DEAL_SL);
      sig.takeProfit=HistoryDealGetDouble(trans.deal,DEAL_TP);
      sig.comment=HistoryDealGetString(trans.deal,DEAL_COMMENT);
      sig.magicNumber=magic;
      sig.orderTicket=(ulong)HistoryDealGetInteger(trans.deal,DEAL_ORDER);
      sig.expiration=0;

      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
         sig.tradeType=SIGNAL_CLOSE;
      else
         sig.tradeType=SIGNAL_MARKET;

      sig.action=MapDealTypeToAction(dealType);
      PublishSignal(sig);
      return;
     }

   if(trans.type==TRADE_TRANSACTION_ORDER_ADD || trans.type==TRADE_TRANSACTION_ORDER_UPDATE)
     {
      ulong orderTicket=trans.order;
      if(orderTicket==0)
         return;
      if(!OrderSelect(orderTicket))
         return;

      long magic=OrderGetInteger(ORDER_MAGIC);
      if(!IsRelevantMagic(magic))
         return;

      ENUM_ORDER_TYPE ordType=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ordType==ORDER_TYPE_BUY || ordType==ORDER_TYPE_SELL)
         return;

      sig.tradeType=(trans.type==TRADE_TRANSACTION_ORDER_ADD ? SIGNAL_PENDING : SIGNAL_MODIFY);
      sig.action=MapOrderTypeToAction(ordType);
      sig.symbol=OrderGetString(ORDER_SYMBOL);
      sig.volume=OrderGetDouble(ORDER_VOLUME_CURRENT);
      sig.price=OrderGetDouble(ORDER_PRICE_OPEN);
      sig.stopLoss=OrderGetDouble(ORDER_SL);
      sig.takeProfit=OrderGetDouble(ORDER_TP);
      sig.comment=OrderGetString(ORDER_COMMENT);
      sig.magicNumber=magic;
      sig.orderTicket=orderTicket;
      sig.expiration=(datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);

      PublishSignal(sig);
      return;
     }

   // Optional FR-3.1.x extension point: position-only updates can be mapped to SIGNAL_MODIFY.
  }
