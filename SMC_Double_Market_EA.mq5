//+------------------------------------------------------------------+
//|                                         SMC_Double_Market_EA.mq5 |
//|                     Added Spread, Time Filters and Trailing Step |
//|  v3.10: исправления без изменения логики (замок Buy+Sell на      |
//|  пробое уровней ликвидности M5)                                  |
//+------------------------------------------------------------------+
#property copyright "SMC & Indicator MTF EA"
#property version   "3.10"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade         trade;
CSymbolInfo    sym;

//--- Входные параметры
input string   SMC_Settings      = "--- Настройки SMC и объемов ---";
input double   InpLotSize        = 0.01;      // Рабочий лот (если InpRiskPercent = 0)
input double   InpRiskPercent    = 0.0;       // Риск на одну ногу замка, % баланса (0 = фиксированный лот)
input int      InpSMC_Range      = 10;        // Количество свечей M5 для пулов ликвидности
input double   InpOrderOffset    = 5.0;       // Отступ от уровней для триггера (в пунктах)

input string   Time_Filters      = "--- Временные и Рыночные фильтры ---";
input int      InpMaxSpread      = 30;        // Максимальный спред (в пунктах)
input int      InpStartHour      = 9;         // Час начала торговли (серверное время)
input int      InpEndHour        = 21;        // Час окончания торговли
input bool     InpFridayClose    = true;      // Закрывать все позиции в пятницу
input int      InpFridayCloseHour = 23;       // Час закрытия в пятницу (серверное время)

input string   Ind_Settings      = "--- Настройки Индикаторов ---";
input int      InpRsiPeriod      = 14;        // RSI Период (H1)
input int      InpAtrPeriod      = 14;        // ATR Период (M5)

input string   Risk_Settings     = "--- Настройки Риск-менеджмента ---";
input double   InpAtrSlMult      = 1.5;       // Множитель ATR для Stop Loss
input double   InpAtrTpMult      = 4.0;       // Множитель ATR для Take Profit
input int      InpTrailingStop   = 250;       // Трейлинг стоп (в пунктах), если InpTrailAtrMult = 0
input int      InpTrailingStep   = 50;        // Шаг трейлинг стопа (в пунктах), если InpTrailAtrMult = 0
input double   InpTrailAtrMult   = 0.0;       // Трейлинг = ATR x (0 = использовать пункты выше)
input double   InpTrailStepAtr   = 0.2;       // Шаг трейлинга = ATR x (если InpTrailAtrMult > 0)
input int      InpSlippage       = 30;        // Проскальзывание (в пунктах)
input ulong    InpMagicNumber    = 888999;    // Magic Number

//--- Хэндлы индикаторов
int      handle_rsi = INVALID_HANDLE, handle_atr = INVALID_HANDLE;
datetime g_lastLockBar = 0;   // свеча M5, на которой открыт последний замок

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Замок невозможен на неттинг-счёте: Sell просто закроет Buy
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("Ошибка: нужен хеджинговый счёт. На неттинг-счёте Buy и Sell взаимно закрываются.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   sym.Name(_Symbol);

   if(!sym.Refresh())
     {
      Print("Ошибка: Не удалось получить данные по символу ", _Symbol);
      return(INIT_FAILED);
     }

   handle_rsi = iRSI(_Symbol, PERIOD_H1, InpRsiPeriod, PRICE_CLOSE);
   handle_atr = iATR(_Symbol, PERIOD_M5, InpAtrPeriod);

   if(handle_rsi == INVALID_HANDLE || handle_atr == INVALID_HANDLE)
     {
      Print("Ошибка загрузки индикаторов!");
      return(INIT_FAILED);
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(handle_rsi != INVALID_HANDLE) IndicatorRelease(handle_rsi);
   if(handle_atr != INVALID_HANDLE) IndicatorRelease(handle_atr);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   if(!sym.RefreshRates()) return;

   MqlDateTime dt;
   TimeCurrent(dt);

   // 0. Закрытие перед выходными
   if(InpFridayClose && dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour)
     {
      CloseAllPositions();
      return;
     }

   //--- Данные индикаторов (ATR нужен и для трейлинга)
   double rsi[], atr[];
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(handle_rsi, 0, 1, 1, rsi) <= 0) return;
   if(CopyBuffer(handle_atr, 0, 1, 1, atr) <= 0) return;

   // 1. Управление трейлинг стопом (выполняется всегда для защиты открытых позиций)
   ManageTrailingStop(atr[0]);

   // Если есть открытые позиции - ждем их полного закрытия
   if(CountActivePositions() > 0) return;

   // Не больше одного замка на одну свечу M5 (раньше замок мог открываться заново на каждом тике)
   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if(barTime == 0 || barTime == g_lastLockBar) return;

   // 2. Фильтр по спреду
   if(sym.Spread() > InpMaxSpread) return;

   // 3. Фильтр по торговому времени (только Пн-Пт)
   if(dt.day_of_week < 1 || dt.day_of_week > 5) return;
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return;
   if(InpFridayClose && dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour - 1) return;

   // Фильтр флэта на H1
   if(rsi[0] < 53 && rsi[0] > 47) return;

   //--- 5. Определение границ ликвидности M5
   double high_arr[], low_arr[];
   ArraySetAsSeries(high_arr, true);
   ArraySetAsSeries(low_arr, true);

   if(CopyHigh(_Symbol, PERIOD_M5, 1, InpSMC_Range, high_arr) < InpSMC_Range) return;
   if(CopyLow(_Symbol, PERIOD_M5, 1, InpSMC_Range, low_arr) < InpSMC_Range) return;

   double liq_high = high_arr[ArrayMaximum(high_arr)];
   double liq_low  = low_arr[ArrayMinimum(low_arr)];

   double point = sym.Point();
   double ask = sym.Ask();
   double bid = sym.Bid();

   //--- 6. Условие пробоя (Вход в замок)
   bool trigger_breakout = (ask > (liq_high + InpOrderOffset * point) || bid < (liq_low - InpOrderOffset * point));
   if(!trigger_breakout) return;

   double atr_value = atr[0];
   double sl_dist = atr_value * InpAtrSlMult;
   double tp_dist = atr_value * InpAtrTpMult;

   // SL/TP не ближе минимального уровня брокера
   double min_dist = (sym.StopsLevel() + sym.Spread()) * point;
   if(sl_dist <= min_dist || tp_dist <= min_dist)
     {
      PrintFormat("Пропуск: SL/TP (%.5f) ближе минимального уровня брокера (%.5f)", sl_dist, min_dist);
      return;
     }

   double lot = CalcLot(sl_dist);
   if(lot <= 0) return;

   double buy_sl  = sym.NormalizePrice(ask - sl_dist);
   double buy_tp  = sym.NormalizePrice(ask + tp_dist);
   double sell_sl = sym.NormalizePrice(bid + sl_dist);
   double sell_tp = sym.NormalizePrice(bid - tp_dist);

   g_lastLockBar = barTime;

   // Открываем Buy
   if(!trade.Buy(lot, _Symbol, ask, buy_sl, buy_tp, "SMC Buy Lock"))
     {
      Print("Ошибка открытия Buy: ", trade.ResultRetcodeDescription());
      return;                                   // без Buy замок не открываем
     }
   ulong buy_ticket = trade.ResultOrder();

   // Открываем Sell
   if(!trade.Sell(lot, _Symbol, bid, sell_sl, sell_tp, "SMC Sell Lock"))
     {
      Print("Ошибка открытия Sell: ", trade.ResultRetcodeDescription(), ". Закрываю Buy, чтобы не остаться без замка.");
      if(buy_ticket > 0 && PositionSelectByTicket(buy_ticket))
         trade.PositionClose(buy_ticket);
     }
  }

//+------------------------------------------------------------------+
//| Лот: фиксированный или по % риска, с учётом мин/макс/шага        |
//+------------------------------------------------------------------+
double CalcLot(double sl_dist)
  {
   double minLot = sym.LotsMin();
   double maxLot = sym.LotsMax();
   double step   = sym.LotsStep();
   double lot    = InpLotSize;

   if(InpRiskPercent > 0)
     {
      double tickSize  = sym.TickSize();
      double tickValue = sym.TickValue();
      if(tickSize <= 0 || tickValue <= 0) return 0.0;
      double lossPerLot = sl_dist / tickSize * tickValue;
      double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      lot = riskMoney / lossPerLot;
     }

   lot = MathFloor(lot / step) * step;
   if(lot < minLot)
     {
      if(InpRiskPercent > 0)
         PrintFormat("Внимание: расчётный лот меньше минимального, используется %.2f", minLot);
      lot = minLot;
     }
   lot = MathMin(lot, maxLot);
   int lotDigits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   lot = NormalizeDouble(lot, lotDigits);

   // Маржа на обе ноги замка
   double margin = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, sym.Ask(), margin) &&
      margin * 2.0 > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      PrintFormat("Пропуск: не хватает маржи на замок (нужно ~%.2f)", margin * 2.0);
      return 0.0;
     }
   return lot;
  }

//+------------------------------------------------------------------+
//| Функция подсчета активных ордеров советника                      |
//+------------------------------------------------------------------+
int CountActivePositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
        {
         count++;
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
        {
         ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
         if(!trade.PositionClose(ticket))
            Print("Ошибка закрытия #", ticket, ": ", trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Функция Трейлинг Стопа с учетом StopsLevel и Шага                |
//+------------------------------------------------------------------+
void ManageTrailingStop(double atr_value)
  {
   double point = sym.Point();
   double trail_dist, trail_step;

   if(InpTrailAtrMult > 0)
     {
      trail_dist = atr_value * InpTrailAtrMult;
      trail_step = atr_value * InpTrailStepAtr;
     }
   else
     {
      if(InpTrailingStop <= 0) return;
      trail_dist = InpTrailingStop * point;
      trail_step = InpTrailingStep * point; // Шаг модификации ордера
     }
   if(trail_dist <= 0) return;

   double min_stop_level = sym.StopsLevel() * point;
   if(trail_dist < min_stop_level) trail_dist = min_stop_level + point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      string pos_symbol = PositionGetSymbol(i);
      if(pos_symbol == _Symbol && PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
        {
         double current_sl = PositionGetDouble(POSITION_SL);
         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         double tp         = PositionGetDouble(POSITION_TP);
         long   pos_type   = PositionGetInteger(POSITION_TYPE);
         ulong  ticket     = (ulong)PositionGetInteger(POSITION_TICKET);

         if(pos_type == POSITION_TYPE_BUY)
           {
            double current_price = sym.Bid();
            double new_sl = sym.NormalizePrice(current_price - trail_dist);
            // Проверка шага: модифицируем только если новый стоп выше старого хотя бы на trail_step
            if(current_price - open_price > trail_dist && (current_sl == 0.0 || new_sl >= current_sl + trail_step))
              {
               if(!trade.PositionModify(ticket, new_sl, tp))
                  Print("Ошибка модификации Buy (Trailing): ", trade.ResultRetcodeDescription());
              }
           }
         else if(pos_type == POSITION_TYPE_SELL)
           {
            double current_price = sym.Ask();
            double new_sl = sym.NormalizePrice(current_price + trail_dist);
            // Проверка шага: модифицируем только если новый стоп ниже старого хотя бы на trail_step
            if(open_price - current_price > trail_dist && (current_sl == 0.0 || new_sl <= current_sl - trail_step))
              {
               if(!trade.PositionModify(ticket, new_sl, tp))
                  Print("Ошибка модификации Sell (Trailing): ", trade.ResultRetcodeDescription());
              }
           }
        }
     }
  }
//+------------------------------------------------------------------+
