//+------------------------------------------------------------------+
//|                                              XAU_ICT_RSI_ATR.mq5 |
//|  XAUUSD: анализ на H1 (RSI 30/70, ATR, опц. ICT структура),      |
//|  вход на M5 (снятие ликвидности / ретест FVG / ретест OB),       |
//|  SL/TP по усреднённому ATR последних закрытых свечей.            |
//+------------------------------------------------------------------+
#property copyright "Trade bot"
#property version   "1.32"
#property description "H1: RSI 30/70 + ATR. M5: Sweep / FVG / Order Block. SL=1.5*ATR, TP=3*ATR."

#include <Trade\Trade.mqh>

//--- Общие
input group "=== Общие ==="
input long            InpMagic          = 20261017;    // Magic number
input ENUM_TIMEFRAMES InpHTF            = PERIOD_H1;   // Таймфрейм анализа (направление)
input ENUM_TIMEFRAMES InpLTF            = PERIOD_M5;   // Таймфрейм входа
input string          InpComment        = "XAU_ICT";   // Комментарий к сделкам

//--- Риск
input group "=== Риск и лот ==="
input double InpRiskPercent     = 1.0;  // Риск на сделку, % от баланса
input double InpFixedLot        = 0.0;  // Фиксированный лот (0 = считать по риску)
input double InpMaxRiskPercent  = 5.0;  // Макс. риск, % (если мин. лот больше расчётного)
input int    InpMaxSpreadPoints = 0;    // Макс. спред в пунктах (0 = не проверять)
input int    InpSlippagePoints  = 30;   // Допустимое проскальзывание, пункты

//--- ATR
input group "=== ATR (SL / TP) ==="
input ENUM_TIMEFRAMES InpATRTF   = PERIOD_H1; // Таймфрейм свечей для ATR
input int             InpATRBars = 5;         // Кол-во закрытых свечей (самая большая и самая маленькая отбрасываются)
input double          InpSLMult  = 1.5;       // Stop Loss = ATR x
input double          InpTPMult  = 3.0;       // Take Profit = ATR x

//--- Трейлинг
input group "=== Трейлинг-стоп ==="
input bool   InpUseTrailing    = false; // Трейлинг на расстоянии (ATR + SL)/2
input bool   InpUseBreakeven   = true;  // Перевод в безубыток
input double InpBETriggerATR   = 1.5;   // Безубыток, когда прибыль >= ATR x (1.5 = 1 стоп)
input double InpBEOffsetATR    = 0.1;   // SL ставится на цену входа + ATR x

//--- RSI
input group "=== RSI (на таймфрейме анализа) ==="
input int    InpRSIPeriod     = 14; // Период RSI
input double InpRSIBuyLevel   = 30; // Buy: RSI H1 <= уровня (перепроданность)
input double InpRSISellLevel  = 70; // Sell: RSI H1 >= уровня (перекупленность)
input int    InpRSILookback   = 3;  // Сколько последних закрытых свечей H1 проверять
input bool   InpUseHTFStructure = false; // Дополнительно требовать BOS на H1 в сторону сделки

//--- ICT
input group "=== ICT ==="
input int  InpHTFLookback        = 150;   // H1: сколько свечей анализировать для структуры
input int  InpHTFSwingStrength   = 3;     // H1: свечей с каждой стороны для swing high/low
input bool InpUsePremiumDiscount = false; // H1: Buy только в discount, Sell только в premium
input int  InpPDBars             = 48;    // H1: свечей для диапазона premium/discount
input bool InpUseSweep           = true;  // M5: вход по снятию ликвидности
input int  InpSweepLookback      = 20;    // M5: свечей для поиска ликвидности
input bool InpUseFVG             = true;  // M5: вход по ретесту Fair Value Gap
input bool InpUseOB              = true;  // M5: вход по ретесту Order Block
input int  InpLTFLookback        = 30;    // M5: свечей для поиска FVG / OB

//--- Время (время сервера брокера)
input group "=== Время (сервер брокера) ==="
input int  InpStartHour      = 8;    // Начало торговли, час (Пн-Пт)
input int  InpStartMinute    = 0;    // Начало торговли, минута
input int  InpEndHour        = 22;   // Конец новых входов, час (Пн-Чт)
input int  InpEndMinute      = 0;    // Конец новых входов, минута
input int  InpFridayEndHour  = 21;   // Пятница: конец новых входов, час
input int  InpFridayEndMin   = 0;    // Пятница: конец новых входов, минута
input int  InpCloseHour      = 23;   // Закрыть все позиции, час
input int  InpCloseMinute    = 0;    // Закрыть все позиции, минута
input bool InpCloseDaily     = false; // Закрывать каждый день в 23:00 (false = только в пятницу)

//--- Глобальные
CTrade   trade;
int      g_rsiHandle = INVALID_HANDLE;
datetime g_lastBar   = 0;
double   g_atr       = 0.0;
string   g_signal    = "";

struct SBar
  {
   double            o, h, l, c;
  };

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpATRBars < 3)
     {
      Print("InpATRBars должен быть >= 3");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpSLMult <= 0 || InpTPMult <= 0 || InpRiskPercent < 0)
     {
      Print("Неверные параметры SL/TP/риска");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      Print("Внимание: советник рассчитан на XAUUSD, текущий символ ", _Symbol);

   g_rsiHandle = iRSI(_Symbol, InpHTF, InpRSIPeriod, PRICE_CLOSE);
   if(g_rsiHandle == INVALID_HANDLE)
     {
      Print("Не удалось создать RSI, ошибка ", GetLastError());
      return INIT_FAILED;
     }

   PrintFormat("Советник v1.32 запущен: ATR TF=%s, RSI %.0f/%.0f, закрытие в %02d:%02d %s",
               EnumToString(InpATRTF), InpRSIBuyLevel, InpRSISellLevel, InpCloseHour, InpCloseMinute,
               InpCloseDaily ? "КАЖДЫЙ ДЕНЬ" : "ТОЛЬКО В ПЯТНИЦУ");

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_rsiHandle != INVALID_HANDLE)
      IndicatorRelease(g_rsiHandle);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(IsCloseTime())
     {
      CloseAll();
      return;
     }

   ManageTrailing();

   datetime barTime = iTime(_Symbol, InpLTF, 0);
   if(barTime == 0 || barTime == g_lastBar)
      return;
   g_lastBar = barTime;

   g_atr = CalcAvgRange();
   TryEntry();
  }

//+------------------------------------------------------------------+
//| Средний ATR: N последних закрытых свечей, без max и min          |
//+------------------------------------------------------------------+
double CalcAvgRange()
  {
   MqlRates r[];
   if(CopyRates(_Symbol, InpATRTF, 1, InpATRBars, r) != InpATRBars)
      return 0.0;

   double ranges[];
   ArrayResize(ranges, InpATRBars);
   for(int i = 0; i < InpATRBars; i++)
      ranges[i] = r[i].high - r[i].low;
   ArraySort(ranges);

   double sum = 0.0;
   for(int i = 1; i < InpATRBars - 1; i++)
      sum += ranges[i];
   return sum / (InpATRBars - 2);
  }

//+------------------------------------------------------------------+
//| Структура H1: 1 = последний BOS вверх, -1 = вниз, 0 = нет        |
//+------------------------------------------------------------------+
int HTFStructure()
  {
   int s = InpHTFSwingStrength;
   MqlRates r[];                                   // r[0] = самая старая свеча
   int got = CopyRates(_Symbol, InpHTF, 1, InpHTFLookback, r);
   if(got < 2 * s + 5)
      return 0;

   double lastSH = 0.0, lastSL = 0.0;
   bool   shBroken = true, slBroken = true;
   int    trend = 0;

   for(int i = 2 * s; i < got; i++)
     {
      // swing на свече j подтверждается после закрытия свечи i = j + s
      int  j = i - s;
      bool isH = true, isL = true;
      for(int k = j - s; k <= j + s; k++)
        {
         if(k == j)
            continue;
         if(k < j)
           {
            if(r[k].high > r[j].high) isH = false;
            if(r[k].low  < r[j].low)  isL = false;
           }
         else
           {
            if(r[k].high >= r[j].high) isH = false;
            if(r[k].low  <= r[j].low)  isL = false;
           }
        }
      if(isH) { lastSH = r[j].high; shBroken = false; }
      if(isL) { lastSL = r[j].low;  slBroken = false; }

      // Break of Structure: закрытие за последним непробитым swing
      if(!shBroken && lastSH > 0 && r[i].close > lastSH) { trend = 1;  shBroken = true; }
      if(!slBroken && lastSL > 0 && r[i].close < lastSL) { trend = -1; slBroken = true; }
     }
   return trend;
  }

//+------------------------------------------------------------------+
//| Направление по RSI H1: 1 = был <= BuyLevel, -1 = был >= SellLevel |
//| за последние InpRSILookback закрытых свечей, 0 = нет сигнала.     |
int RSIDirection(double &lastRsi)
  {
   int n = MathMax(1, InpRSILookback);
   double buf[];
   ArraySetAsSeries(buf, true);                    // buf[0] = последняя закрытая свеча
   if(CopyBuffer(g_rsiHandle, 0, 1, n, buf) != n)
      return 0;
   lastRsi = buf[0];
   for(int i = 0; i < n; i++)
     {
      if(buf[i] <= InpRSIBuyLevel)  return 1;
      if(buf[i] >= InpRSISellLevel) return -1;
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| Premium / Discount: true если цена в нужной половине диапазона   |
//+------------------------------------------------------------------+
bool PremiumDiscountOK(int dir, double price)
  {
   MqlRates r[];
   int got = CopyRates(_Symbol, InpHTF, 1, InpPDBars, r);
   if(got <= 0)
      return false;
   double hi = r[0].high, lo = r[0].low;
   for(int i = 1; i < got; i++)
     {
      hi = MathMax(hi, r[i].high);
      lo = MathMin(lo, r[i].low);
     }
   double mid = (hi + lo) / 2.0;
   return (dir == 1) ? (price < mid) : (price > mid);
  }

//+------------------------------------------------------------------+
//| Свечи M5, b[0] = последняя закрытая. Для Sell цены зеркалятся    |
//| (умножаются на -1), чтобы одна логика работала в обе стороны.    |
//+------------------------------------------------------------------+
bool LoadBars(int dir, SBar &b[], int count)
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpLTF, 1, count, r) != count)
      return false;
   ArrayResize(b, count);
   for(int i = 0; i < count; i++)
     {
      if(dir == 1)
        {
         b[i].o = r[i].open; b[i].h = r[i].high;
         b[i].l = r[i].low;  b[i].c = r[i].close;
        }
      else
        {
         b[i].o = -r[i].open; b[i].h = -r[i].low;
         b[i].l = -r[i].high; b[i].c = -r[i].close;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Сигнал на M5 (логика описана для Buy, Sell зеркально)             |
//+------------------------------------------------------------------+
bool LTFSignal(int dir)
  {
   int need = MathMax(InpLTFLookback + 6, InpSweepLookback + 2);
   SBar b[];
   if(!LoadBars(dir, b, need))
      return false;

   // свеча-триггер должна закрыться в сторону сделки
   if(!(b[0].c > b[0].o))
      return false;

   // 1) Снятие ликвидности: прокол минимума последних свечей и закрытие выше него
   if(InpUseSweep)
     {
      double mn = DBL_MAX;
      for(int i = 1; i <= InpSweepLookback; i++)
         mn = MathMin(mn, b[i].l);
      if(b[0].l < mn && b[0].c > mn)
        {
         g_signal = "Sweep";
         return true;
        }
     }

   // 2) FVG / 3) Order Block
   if(InpUseFVG || InpUseOB)
     {
      for(int k = 1; k <= InpLTFLookback && k + 5 < need; k++)
        {
         // бычий FVG из трёх свечей: b[k+2] (старая), b[k+1], b[k] (новая)
         double bottom = b[k + 2].h;
         double top    = b[k].l;
         if(top <= bottom)
            continue;

         // зона не должна быть пробита закрытием после формирования
         bool valid = true;
         for(int m = 1; m < k; m++)
            if(b[m].c < bottom) { valid = false; break; }
         if(!valid)
            continue;

         if(InpUseFVG && b[0].l <= top && b[0].c > top)
           {
            g_signal = "FVG";
            return true;
           }

         if(InpUseOB)
           {
            // OB = последняя противоположная свеча перед импульсом, создавшим FVG
            for(int ob = k + 2; ob <= k + 4; ob++)
              {
               if(b[ob].c < b[ob].o)
                 {
                  double obH = b[ob].h, obL = b[ob].l;
                  bool ok = true;
                  for(int m = 1; m < ob; m++)
                     if(b[m].c < obL) { ok = false; break; }
                  if(ok && b[0].l <= obH && b[0].c > obH)
                    {
                     g_signal = "OB";
                     return true;
                    }
                  break;
                 }
              }
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
void TryEntry()
  {
   if(HasPosition() || !IsEntryTime())
      return;

   if(InpMaxSpreadPoints > 0 && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPoints)
      return;

   // --- направление по H1
   double rsi = 0.0;
   int    dir = RSIDirection(rsi);
   if(dir == 0)
      return;
   if(InpUseHTFStructure && HTFStructure() != dir)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   double price = (dir == 1) ? tick.ask : tick.bid;

   if(InpUsePremiumDiscount && !PremiumDiscountOK(dir, price))
      return;

   // --- триггер на M5
   if(!LTFSignal(dir))
      return;

   // --- SL / TP
   double atr = (g_atr > 0) ? g_atr : CalcAvgRange();
   if(atr <= 0)
      return;
   double slDist = atr * InpSLMult;
   double tpDist = atr * InpTPMult;

   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slDist <= minDist || tpDist <= minDist)
     {
      PrintFormat("SL/TP ближе минимального уровня брокера: SL=%.2f, min=%.2f", slDist, minDist);
      return;
     }

   double sl = NormalizePrice(dir == 1 ? price - slDist : price + slDist);
   double tp = NormalizePrice(dir == 1 ? price + tpDist : price - tpDist);

   double lot = CalcLot(dir, price, slDist);
   if(lot <= 0)
      return;

   string cmt = InpComment + " " + g_signal;
   bool ok = (dir == 1) ? trade.Buy(lot, _Symbol, price, sl, tp, cmt)
                        : trade.Sell(lot, _Symbol, price, sl, tp, cmt);

   PrintFormat("%s %s lot=%.2f price=%.2f SL=%.2f TP=%.2f ATR=%.2f RSI(H1)=%.1f %s",
               ok ? "Открыта" : "Ошибка открытия",
               dir == 1 ? "BUY" : "SELL", lot, price, sl, tp, atr, rsi,
               ok ? g_signal : ("код " + (string)trade.ResultRetcode()));
  }

//+------------------------------------------------------------------+
//| Лот по % риска от баланса                                        |
//+------------------------------------------------------------------+
double CalcLot(int dir, double price, double slDist)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   ENUM_ORDER_TYPE type = (dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double lot;

   if(InpFixedLot > 0)
      lot = InpFixedLot;
   else
     {
      double profit = 0.0;
      double slPrice = (dir == 1) ? price - slDist : price + slDist;
      double lossPerLot;
      if(OrderCalcProfit(type, _Symbol, 1.0, price, slPrice, profit))
         lossPerLot = MathAbs(profit);
      else
        {
         double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         lossPerLot = (tickSize > 0) ? slDist / tickSize * tickValue : 0.0;
        }
      if(lossPerLot <= 0 || balance <= 0)
         return 0.0;

      double riskMoney = balance * InpRiskPercent / 100.0;
      lot = MathFloor(riskMoney / lossPerLot / step) * step;

      if(lot < minLot)
        {
         double riskAtMin = lossPerLot * minLot / balance * 100.0;
         if(riskAtMin > InpMaxRiskPercent)
           {
            PrintFormat("Пропуск: мин. лот %.2f = риск %.1f%% (> %.1f%%)", minLot, riskAtMin, InpMaxRiskPercent);
            return 0.0;
           }
         PrintFormat("Внимание: используется мин. лот %.2f, риск %.1f%%", minLot, riskAtMin);
         lot = minLot;
        }
     }

   lot = MathMax(minLot, MathMin(maxLot, lot));
   int lotDigits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   lot = NormalizeDouble(lot, lotDigits);

   double margin = 0.0;
   if(OrderCalcMargin(type, _Symbol, lot, price, margin) &&
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      PrintFormat("Пропуск: не хватает маржи (нужно %.2f)", margin);
      return 0.0;
     }
   return lot;
  }

//+------------------------------------------------------------------+
//| Трейлинг: дистанция = (ATR + SL-дистанция) / 2                   |
//| Включается, когда прибыль достигла этой дистанции.               |
//+------------------------------------------------------------------+
void ManageTrailing()
  {
   if((!InpUseTrailing && !InpUseBreakeven) || g_atr <= 0)
      return;

   double trail   = (g_atr + g_atr * InpSLMult) / 2.0;
   double stepMin = g_atr * 0.1;
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);

      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);

      // безубыток: SL за цену входа, когда цена прошла InpBETriggerATR x ATR
      if(InpUseBreakeven)
        {
         double profitDist = isBuy ? tick.bid - open : open - tick.ask;
         double beSL = NormalizePrice(isBuy ? open + g_atr * InpBEOffsetATR
                                            : open - g_atr * InpBEOffsetATR);
         bool needBE = isBuy ? (sl == 0 || sl < beSL) : (sl == 0 || sl > beSL);
         bool farOK  = isBuy ? (tick.bid - beSL > minDist) : (beSL - tick.ask > minDist);
         if(profitDist >= g_atr * InpBETriggerATR && needBE && farOK)
           {
            if(trade.PositionModify(ticket, beSL, tp))
               sl = beSL;
           }
        }

      if(!InpUseTrailing)
         continue;

      if(isBuy)
        {
         if(tick.bid - open < trail)
            continue;
         double newSL = NormalizePrice(tick.bid - trail);
         if((sl == 0 || newSL > sl + stepMin) && tick.bid - newSL > minDist)
            trade.PositionModify(ticket, newSL, tp);
        }
      else
        {
         if(open - tick.ask < trail)
            continue;
         double newSL = NormalizePrice(tick.ask + trail);
         if((sl == 0 || newSL < sl - stepMin) && newSL - tick.ask > minDist)
            trade.PositionModify(ticket, newSL, tp);
        }
     }
  }

//+------------------------------------------------------------------+
//| Время                                                            |
//+------------------------------------------------------------------+
bool IsEntryTime()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week < 1 || dt.day_of_week > 5)
      return false;

   int now   = dt.hour * 60 + dt.min;
   int start = InpStartHour * 60 + InpStartMinute;
   int end   = (dt.day_of_week == 5) ? InpFridayEndHour * 60 + InpFridayEndMin
                                     : InpEndHour * 60 + InpEndMinute;
   return now >= start && now < end;
  }

bool IsCloseTime()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week < 1 || dt.day_of_week > 5)
      return true;
   if(!InpCloseDaily && dt.day_of_week != 5)
      return false;
   return dt.hour * 60 + dt.min >= InpCloseHour * 60 + InpCloseMinute;
  }

//+------------------------------------------------------------------+
//| Позиции                                                          |
//+------------------------------------------------------------------+
bool IsOurPosition()
  {
   return PositionGetString(POSITION_SYMBOL) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagic;
  }

bool HasPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) > 0 && IsOurPosition())
         return true;
   return false;
  }

void CloseAll()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && IsOurPosition())
         if(!trade.PositionClose(ticket))
            PrintFormat("Не удалось закрыть #%I64u, код %u", ticket, trade.ResultRetcode());
     }
  }

double NormalizePrice(double price)
  {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0)
      price = MathRound(price / tickSize) * tickSize;
   return NormalizeDouble(price, _Digits);
  }
//+------------------------------------------------------------------+
