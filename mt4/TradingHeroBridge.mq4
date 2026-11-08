#property strict
#property version   "1.08"
#property description "TradingHero local MT4 trading bridge"

input string BridgeUrl = "http://127.0.0.1";
input string BridgeToken = "";
input int PollIntervalMilliseconds = 300;
input int SnapshotIntervalMilliseconds = 1000;
input int SymbolRefreshIntervalMilliseconds = 30000;
input int RequestTimeoutMilliseconds = 2000;
input int HistoryOrderLimit = 1000;
input bool AllowLiveTrading = false;
input int DefaultSlippagePoints = 20;
input int DefaultMagicNumber = 20261107;

string EA_VERSION = "1.08";
string g_bridgeUrl = "";
string g_bridgeToken = "";
bool g_busy = false;
uint g_lastSnapshotAt = 0;
uint g_lastSymbolsAt = 0;
string g_pendingResults = "";
int g_lastWebRequestError = 0;
uint g_lastWebRequestErrorAt = 0;
int g_previousCloseWarmupIndex = 0;

int OnInit()
{
   g_bridgeUrl = BridgeUrl;
   g_bridgeToken = BridgeToken;
   LoadBridgeConfig();
   if(StringLen(g_bridgeToken) < 24)
   {
      Print("TradingHeroBridge: bridge token is missing. Start TradingHero once or set BridgeToken manually.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   int interval = MathMax(200, PollIntervalMilliseconds);
   if(!EventSetMillisecondTimer(interval))
   {
      Print("TradingHeroBridge: cannot start timer, error=", GetLastError());
      return(INIT_FAILED);
   }
   Print("TradingHeroBridge started. Add ", g_bridgeUrl, " to Tools > Options > Expert Advisors > Allow WebRequest.");
   return(INIT_SUCCEEDED);
}

void LoadBridgeConfig()
{
   ResetLastError();
   int handle = FileOpen("TradingHero\\bridge.conf", FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
   {
      Print("TradingHeroBridge: cannot open MQL4\\Files\\TradingHero\\bridge.conf, error=", GetLastError());
      return;
   }
   if(!FileIsEnding(handle)) g_bridgeUrl = FileReadString(handle);
   if(!FileIsEnding(handle)) g_bridgeToken = FileReadString(handle);
   FileClose(handle);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   if(g_busy)
      return;
   g_busy = true;
   FlushResults();
   uint now = GetTickCount();
   if(g_lastSnapshotAt == 0 || now - g_lastSnapshotAt >= (uint)MathMax(500, SnapshotIntervalMilliseconds))
   {
      if(SendSnapshot())
         g_lastSnapshotAt = now;
   }
   PollCommands();
   FlushResults();
   WarmPreviousClose();
   g_busy = false;
}

string TerminalId()
{
   return(IntegerToString(AccountNumber()) + "@" + AccountServer());
}

string TrimBridgeUrl()
{
   string value = g_bridgeUrl;
   while(StringLen(value) > 0 && StringSubstr(value, StringLen(value) - 1, 1) == "/")
      value = StringSubstr(value, 0, StringLen(value) - 1);
   return(value);
}

string HexByte(int value)
{
   string hex = "0123456789ABCDEF";
   return(StringSubstr(hex, (value >> 4) & 15, 1) + StringSubstr(hex, value & 15, 1));
}

int HexValue(int character)
{
   if(character >= '0' && character <= '9') return(character - '0');
   if(character >= 'A' && character <= 'F') return(character - 'A' + 10);
   if(character >= 'a' && character <= 'f') return(character - 'a' + 10);
   return(-1);
}

string UrlEncode(string value)
{
   uchar bytes[];
   int count = StringToCharArray(value, bytes, 0, WHOLE_ARRAY, CP_UTF8);
   string output = "";
   for(int i = 0; i < count - 1; i++)
   {
      int code = (int)bytes[i];
      bool safe = (code >= 'A' && code <= 'Z') || (code >= 'a' && code <= 'z') ||
                  (code >= '0' && code <= '9') || code == '-' || code == '_' || code == '.' || code == '~';
      output += safe ? CharToString((uchar)code) : "%" + HexByte(code);
   }
   return(output);
}

string UrlDecode(string value)
{
   uchar bytes[];
   ArrayResize(bytes, StringLen(value) + 1);
   int output = 0;
   for(int i = 0; i < StringLen(value); i++)
   {
      int code = StringGetCharacter(value, i);
      if(code == '%' && i + 2 < StringLen(value))
      {
         int high = HexValue(StringGetCharacter(value, i + 1));
         int low = HexValue(StringGetCharacter(value, i + 2));
         if(high >= 0 && low >= 0)
         {
            bytes[output++] = (uchar)(high * 16 + low);
            i += 2;
            continue;
         }
      }
      if(code == '+') code = ' ';
      bytes[output++] = (uchar)code;
   }
   bytes[output] = 0;
   return(CharArrayToString(bytes, 0, output, CP_UTF8));
}

string Field(string key, string value)
{
   return(key + "=" + UrlEncode(value));
}

string FieldNumber(string key, double value, int digits = 8)
{
   return(Field(key, DoubleToString(value, digits)));
}

string FieldInteger(string key, long value)
{
   return(Field(key, IntegerToString((int)value)));
}

string AddField(string line, string key, string value)
{
   if(StringLen(line) > 0 && StringSubstr(line, StringLen(line) - 1, 1) != "?") line += "&";
   return(line + Field(key, value));
}

string AddNumber(string line, string key, double value, int digits = 8)
{
   return(AddField(line, key, DoubleToString(value, digits)));
}

string AddInteger(string line, string key, long value)
{
   return(AddField(line, key, IntegerToString((int)value)));
}

string OrderTypeName(int orderType)
{
   if(orderType == OP_BUY) return("buy");
   if(orderType == OP_SELL) return("sell");
   if(orderType == OP_BUYLIMIT) return("buy_limit");
   if(orderType == OP_SELLLIMIT) return("sell_limit");
   if(orderType == OP_BUYSTOP) return("buy_stop");
   if(orderType == OP_SELLSTOP) return("sell_stop");
   if(orderType == 6) return("balance");
   if(orderType == 7) return("credit");
   return("unknown");
}

string BuildMetaRecord()
{
   string line = "meta?";
   line = AddField(line, "terminalId", TerminalId());
   line = AddField(line, "terminalName", TerminalName());
   line = AddInteger(line, "terminalBuild", TerminalInfoInteger(TERMINAL_BUILD));
   line = AddField(line, "eaVersion", EA_VERSION);
   line = AddField(line, "chartSymbol", Symbol());
   return(line);
}

string BuildAccountRecord()
{
   string line = "account?";
   line = AddInteger(line, "login", AccountNumber());
   line = AddField(line, "name", AccountName());
   line = AddField(line, "company", AccountCompany());
   line = AddField(line, "server", AccountServer());
   line = AddField(line, "currency", AccountCurrency());
   line = AddInteger(line, "leverage", AccountLeverage());
   line = AddNumber(line, "balance", AccountBalance(), 2);
   line = AddNumber(line, "equity", AccountEquity(), 2);
   line = AddNumber(line, "margin", AccountMargin(), 2);
   line = AddNumber(line, "freeMargin", AccountFreeMargin(), 2);
   line = AddNumber(line, "marginLevel", AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), 2);
   line = AddNumber(line, "profit", AccountProfit(), 2);
   line = AddInteger(line, "tradeAllowed", AllowLiveTrading && IsTradeAllowed() ? 1 : 0);
   line = AddInteger(line, "connected", IsConnected() ? 1 : 0);
   return(line);
}

string BuildOpenOrderRecord()
{
   int type = OrderType();
   bool market = type == OP_BUY || type == OP_SELL;
   string line = market ? "position?" : "order?";
   line = AddInteger(line, "ticket", OrderTicket());
   line = AddField(line, "symbol", OrderSymbol());
   if(market)
      line = AddField(line, "side", OrderTypeName(type));
   else
      line = AddField(line, "type", OrderTypeName(type));
   line = AddNumber(line, "volume", OrderLots(), 4);
   line = AddNumber(line, "openPrice", OrderOpenPrice());
   double currentPrice = type == OP_BUY ? MarketInfo(OrderSymbol(), MODE_BID) : MarketInfo(OrderSymbol(), MODE_ASK);
   line = AddNumber(line, "currentPrice", currentPrice);
   line = AddNumber(line, "stopLoss", OrderStopLoss());
   line = AddNumber(line, "takeProfit", OrderTakeProfit());
   line = AddInteger(line, "magic", OrderMagicNumber());
   line = AddField(line, "comment", OrderComment());
   line = AddInteger(line, "openedAt", OrderOpenTime());
   if(market)
   {
      line = AddNumber(line, "profit", OrderProfit(), 2);
      line = AddNumber(line, "swap", OrderSwap(), 2);
      line = AddNumber(line, "commission", OrderCommission(), 2);
   }
   else
      line = AddInteger(line, "expiration", OrderExpiration());
   return(line);
}

string BuildHistoryRecord()
{
   string line = "history?";
   line = AddInteger(line, "ticket", OrderTicket());
   line = AddField(line, "symbol", OrderSymbol());
   line = AddField(line, "type", OrderTypeName(OrderType()));
   line = AddNumber(line, "volume", OrderLots(), 4);
   line = AddNumber(line, "openPrice", OrderOpenPrice());
   line = AddNumber(line, "closePrice", OrderClosePrice());
   line = AddNumber(line, "stopLoss", OrderStopLoss());
   line = AddNumber(line, "takeProfit", OrderTakeProfit());
   line = AddNumber(line, "profit", OrderProfit(), 2);
   line = AddNumber(line, "swap", OrderSwap(), 2);
   line = AddNumber(line, "commission", OrderCommission(), 2);
   line = AddInteger(line, "magic", OrderMagicNumber());
   line = AddField(line, "comment", OrderComment());
   line = AddInteger(line, "openedAt", OrderOpenTime());
   line = AddInteger(line, "closedAt", OrderCloseTime());
   return(line);
}

string SessionTime(datetime value)
{
   return(StringFormat("%02d:%02d", TimeHour(value), TimeMinute(value)));
}

string SymbolSessionRanges(string symbol, int dayOfWeek, bool quoteSession)
{
   string ranges = "";
   for(uint sessionIndex = 0; sessionIndex < 16; sessionIndex++)
   {
      datetime sessionFrom = 0;
      datetime sessionTo = 0;
      bool found = false;
      if(quoteSession)
         found = SymbolInfoSessionQuote(symbol, (ENUM_DAY_OF_WEEK)dayOfWeek, sessionIndex, sessionFrom, sessionTo);
      else
         found = SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)dayOfWeek, sessionIndex, sessionFrom, sessionTo);
      if(!found)
         break;
      if(StringLen(ranges) > 0)
         ranges += "|";
      ranges += SessionTime(sessionFrom) + "-" + SessionTime(sessionTo);
   }
   return(ranges);
}

string BuildSymbolRecord(string symbol)
{
   string line = "symbol?";
   line = AddField(line, "name", symbol);
   string description = "";
   SymbolInfoString(symbol, SYMBOL_DESCRIPTION, description);
   line = AddField(line, "description", description);
   string path = "";
   SymbolInfoString(symbol, SYMBOL_PATH, path);
   line = AddField(line, "path", path);
   long selected = 0;
   SymbolInfoInteger(symbol, SYMBOL_SELECT, selected);
   line = AddInteger(line, "selected", selected);
   line = AddInteger(line, "spread", (long)MarketInfo(symbol, MODE_SPREAD));
   long spreadFloat = 0;
   SymbolInfoInteger(symbol, SYMBOL_SPREAD_FLOAT, spreadFloat);
   line = AddInteger(line, "spreadFloat", spreadFloat);
   line = AddInteger(line, "digits", (long)MarketInfo(symbol, MODE_DIGITS));
   line = AddInteger(line, "stopsLevel", (long)MarketInfo(symbol, MODE_STOPLEVEL));
   line = AddInteger(line, "freezeLevel", (long)MarketInfo(symbol, MODE_FREEZELEVEL));
   line = AddNumber(line, "contractSize", MarketInfo(symbol, MODE_LOTSIZE), 8);
   string currencyBase = "";
   string currencyProfit = "";
   string currencyMargin = "";
   SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE, currencyBase);
   SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT, currencyProfit);
   SymbolInfoString(symbol, SYMBOL_CURRENCY_MARGIN, currencyMargin);
   line = AddField(line, "currencyBase", currencyBase);
   line = AddField(line, "currencyProfit", currencyProfit);
   line = AddField(line, "currencyMargin", currencyMargin);
   line = AddInteger(line, "profitCalculationMode", (long)MarketInfo(symbol, MODE_PROFITCALCMODE));
   line = AddInteger(line, "marginCalculationMode", (long)MarketInfo(symbol, MODE_MARGINCALCMODE));
   line = AddNumber(line, "marginInitial", MarketInfo(symbol, MODE_MARGININIT), 8);
   line = AddNumber(line, "marginMaintenance", MarketInfo(symbol, MODE_MARGINMAINTENANCE), 8);
   line = AddNumber(line, "marginHedged", MarketInfo(symbol, MODE_MARGINHEDGED), 8);
   line = AddNumber(line, "marginRequired", MarketInfo(symbol, MODE_MARGINREQUIRED), 8);
   long tradeMode = 0;
   long executionMode = 0;
   long swapRollover3Days = 0;
   SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE, tradeMode);
   SymbolInfoInteger(symbol, SYMBOL_TRADE_EXEMODE, executionMode);
   SymbolInfoInteger(symbol, SYMBOL_SWAP_ROLLOVER3DAYS, swapRollover3Days);
   line = AddInteger(line, "tradeMode", tradeMode);
   line = AddInteger(line, "executionMode", executionMode);
   line = AddNumber(line, "minVolume", MarketInfo(symbol, MODE_MINLOT), 8);
   line = AddNumber(line, "maxVolume", MarketInfo(symbol, MODE_MAXLOT), 8);
   line = AddNumber(line, "volumeStep", MarketInfo(symbol, MODE_LOTSTEP), 8);
   line = AddInteger(line, "swapMode", (long)MarketInfo(symbol, MODE_SWAPTYPE));
   line = AddNumber(line, "swapLong", MarketInfo(symbol, MODE_SWAPLONG), 8);
   line = AddNumber(line, "swapShort", MarketInfo(symbol, MODE_SWAPSHORT), 8);
   line = AddInteger(line, "swapRollover3Days", swapRollover3Days);
   for(int dayOfWeek = 0; dayOfWeek < 7; dayOfWeek++)
   {
      line = AddField(line, "quoteSessions" + IntegerToString(dayOfWeek), SymbolSessionRanges(symbol, dayOfWeek, true));
      line = AddField(line, "tradeSessions" + IntegerToString(dayOfWeek), SymbolSessionRanges(symbol, dayOfWeek, false));
   }
   return(line);
}

double PreviousClose(string symbol)
{
   if(SeriesInfoInteger(symbol, PERIOD_D1, SERIES_SYNCHRONIZED) <= 0)
      return(0);
   return(iClose(symbol, PERIOD_D1, 1));
}

void WarmPreviousClose()
{
   int symbolCount = SymbolsTotal(true);
   if(symbolCount <= 0)
      return;
   if(g_previousCloseWarmupIndex >= symbolCount)
      g_previousCloseWarmupIndex = 0;
   string symbol = SymbolName(g_previousCloseWarmupIndex, true);
   g_previousCloseWarmupIndex++;
   if(StringLen(symbol) == 0 || SeriesInfoInteger(symbol, PERIOD_D1, SERIES_SYNCHRONIZED) > 0)
      return;
   double closes[];
   CopyClose(symbol, PERIOD_D1, 1, 1, closes);
}

string BuildQuoteRecord(string symbol)
{
   int digits = (int)MarketInfo(symbol, MODE_DIGITS);
   string line = "quote?";
   line = AddField(line, "symbol", symbol);
   line = AddNumber(line, "bid", MarketInfo(symbol, MODE_BID), digits);
   line = AddNumber(line, "ask", MarketInfo(symbol, MODE_ASK), digits);
   line = AddNumber(line, "high", MarketInfo(symbol, MODE_HIGH), digits);
   line = AddNumber(line, "low", MarketInfo(symbol, MODE_LOW), digits);
   line = AddNumber(line, "previousClose", PreviousClose(symbol), digits);
   line = AddInteger(line, "digits", digits);
   line = AddInteger(line, "timestamp", (long)MarketInfo(symbol, MODE_TIME));
   return(line);
}

string BuildSnapshot(bool includeSymbols)
{
   string body = BuildMetaRecord() + "\n" + BuildAccountRecord();
   int symbolCount = SymbolsTotal(true);
   for(int s = 0; s < symbolCount; s++)
   {
      string symbolName = SymbolName(s, true);
      if(StringLen(symbolName) > 0)
      {
         body += "\n" + BuildQuoteRecord(symbolName);
         if(includeSymbols)
            body += "\n" + BuildSymbolRecord(symbolName);
      }
   }
   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         body += "\n" + BuildOpenOrderRecord();
   }
   int limit = MathMin(MathMax(0, HistoryOrderLimit), OrdersHistoryTotal());
   for(int h = OrdersHistoryTotal() - 1; h >= OrdersHistoryTotal() - limit; h--)
   {
      if(h >= 0 && OrderSelect(h, SELECT_BY_POS, MODE_HISTORY))
         body += "\n" + BuildHistoryRecord();
   }
   return(body);
}

bool HttpRequest(string method, string path, string body, string &response)
{
   string separator = StringFind(path, "?") >= 0 ? "&" : "?";
   string url = TrimBridgeUrl() + path + separator + "token=" + UrlEncode(g_bridgeToken);
   string headers = "Content-Type: text/plain; charset=utf-8\r\nConnection: close\r\n";
   char data[];
   char result[];
   string resultHeaders = "";
   if(StringLen(body) > 0)
   {
      StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
      if(ArraySize(data) > 0) ArrayResize(data, ArraySize(data) - 1);
   }
   else
      ArrayResize(data, 0);
   ResetLastError();
   int status = WebRequest(method, url, headers, RequestTimeoutMilliseconds, data, result, resultHeaders);
   if(status == -1)
   {
      int error = GetLastError();
      uint now = GetTickCount();
      if(error != g_lastWebRequestError || now - g_lastWebRequestErrorAt >= 5000)
      {
         if(error == 4060)
            Print("TradingHeroBridge: WebRequest is blocked. Add ", g_bridgeUrl, " to the allowed URL list.");
         else if(error == 5200)
            Print("TradingHeroBridge: invalid WebRequest URL. Use http://127.0.0.1 without a custom port. url=", url);
         else
            Print("TradingHeroBridge: WebRequest failed, error=", error, ", url=", url);
         g_lastWebRequestError = error;
         g_lastWebRequestErrorAt = now;
      }
      return(false);
   }
   g_lastWebRequestError = 0;
   response = CharArrayToString(result, 0, -1, CP_UTF8);
   if(status < 200 || status >= 300)
   {
      Print("TradingHeroBridge: HTTP ", status, " ", response);
      return(false);
   }
   return(true);
}

bool SendSnapshot()
{
   uint now = GetTickCount();
   bool includeSymbols = g_lastSymbolsAt == 0 ||
      now - g_lastSymbolsAt >= (uint)MathMax(5000, SymbolRefreshIntervalMilliseconds);
   string response = "";
   if(!HttpRequest("POST", "/v1/snapshot", BuildSnapshot(includeSymbols), response))
      return(false);
   if(includeSymbols)
      g_lastSymbolsAt = now;
   return(true);
}

string GetParam(string query, string key)
{
   string parts[];
   int count = StringSplit(query, '&', parts);
   for(int i = 0; i < count; i++)
   {
      int equals = StringFind(parts[i], "=");
      string itemKey = equals >= 0 ? StringSubstr(parts[i], 0, equals) : parts[i];
      if(itemKey == key)
         return(equals >= 0 ? UrlDecode(StringSubstr(parts[i], equals + 1)) : "");
   }
   return("");
}

bool HasParam(string query, string key)
{
   string marker = key + "=";
   return(StringFind("&" + query, "&" + marker) >= 0);
}

double ParamDouble(string query, string key, double fallback)
{
   string value = GetParam(query, key);
   return(StringLen(value) > 0 ? StringToDouble(value) : fallback);
}

int ParamInt(string query, string key, int fallback)
{
   string value = GetParam(query, key);
   return(StringLen(value) > 0 ? (int)StringToInteger(value) : fallback);
}

double NormalizeLots(string symbol, double lots)
{
   double minimum = MarketInfo(symbol, MODE_MINLOT);
   double maximum = MarketInfo(symbol, MODE_MAXLOT);
   double step = MarketInfo(symbol, MODE_LOTSTEP);
   if(step <= 0) step = 0.01;
   lots = MathMax(minimum, MathMin(maximum, lots));
   lots = MathFloor(lots / step + 0.0000001) * step;
   return(NormalizeDouble(lots, 2));
}

double NormalizePrice(string symbol, double price)
{
   return(NormalizeDouble(price, (int)MarketInfo(symbol, MODE_DIGITS)));
}

void AppendResult(string requestId, bool ok, int ticket, int errorCode, string message)
{
   string line = "result?";
   line = AddField(line, "requestId", requestId);
   line = AddInteger(line, "ok", ok ? 1 : 0);
   if(ticket > 0) line = AddInteger(line, "ticket", ticket);
   if(errorCode != 0) line = AddInteger(line, "errorCode", errorCode);
   if(StringLen(message) > 0) line = AddField(line, "message", message);
   if(StringLen(g_pendingResults) > 0) g_pendingResults += "\n";
   g_pendingResults += line;
}

void FlushResults()
{
   if(StringLen(g_pendingResults) == 0)
      return;
   string response = "";
   if(HttpRequest("POST", "/v1/results", g_pendingResults, response))
      g_pendingResults = "";
}

bool CanTrade(string requestId)
{
   if(!AllowLiveTrading)
   {
      AppendResult(requestId, false, 0, 0, "EA setting AllowLiveTrading is disabled");
      return(false);
   }
   if(!IsConnected() || !IsTradeAllowed())
   {
      AppendResult(requestId, false, 0, 0, "MT4 trading is not allowed or terminal is disconnected");
      return(false);
   }
   return(true);
}

void ExecutePlaceMarket(string requestId, string query)
{
   if(!CanTrade(requestId)) return;
   string symbol = GetParam(query, "symbol");
   string side = GetParam(query, "side");
   if(!SymbolSelect(symbol, true))
   {
      AppendResult(requestId, false, 0, GetLastError(), "Cannot select symbol");
      return;
   }
   int type = side == "buy" ? OP_BUY : side == "sell" ? OP_SELL : -1;
   if(type < 0)
   {
      AppendResult(requestId, false, 0, 0, "Invalid market side");
      return;
   }
   double lots = NormalizeLots(symbol, ParamDouble(query, "volume", 0));
   double price = NormalizePrice(symbol, MarketInfo(symbol, type == OP_BUY ? MODE_ASK : MODE_BID));
   double sl = NormalizePrice(symbol, ParamDouble(query, "stopLoss", 0));
   double tp = NormalizePrice(symbol, ParamDouble(query, "takeProfit", 0));
   int slippage = ParamInt(query, "deviation", DefaultSlippagePoints);
   int magic = ParamInt(query, "magic", DefaultMagicNumber);
   string comment = GetParam(query, "comment");
   if(StringLen(comment) == 0) comment = "TradingHero";
   ResetLastError();
   int ticket = OrderSend(symbol, type, lots, price, slippage, sl, tp, comment, magic, 0, clrNONE);
   int error = GetLastError();
   AppendResult(requestId, ticket > 0, ticket, ticket > 0 ? 0 : error,
                ticket > 0 ? "Market order placed" : "OrderSend failed");
}

void ExecutePlacePending(string requestId, string query)
{
   if(!CanTrade(requestId)) return;
   string symbol = GetParam(query, "symbol");
   string typeName = GetParam(query, "type");
   if(!SymbolSelect(symbol, true))
   {
      AppendResult(requestId, false, 0, GetLastError(), "Cannot select symbol");
      return;
   }
   int type = typeName == "buy_limit" ? OP_BUYLIMIT :
              typeName == "sell_limit" ? OP_SELLLIMIT :
              typeName == "buy_stop" ? OP_BUYSTOP :
              typeName == "sell_stop" ? OP_SELLSTOP : -1;
   if(type < 0)
   {
      AppendResult(requestId, false, 0, 0, "Invalid pending order type");
      return;
   }
   double lots = NormalizeLots(symbol, ParamDouble(query, "volume", 0));
   double price = NormalizePrice(symbol, ParamDouble(query, "price", 0));
   double sl = NormalizePrice(symbol, ParamDouble(query, "stopLoss", 0));
   double tp = NormalizePrice(symbol, ParamDouble(query, "takeProfit", 0));
   datetime expiration = (datetime)ParamInt(query, "expiration", 0);
   int magic = ParamInt(query, "magic", DefaultMagicNumber);
   string comment = GetParam(query, "comment");
   if(StringLen(comment) == 0) comment = "TradingHero";
   ResetLastError();
   int ticket = OrderSend(symbol, type, lots, price, 0, sl, tp, comment, magic, expiration, clrNONE);
   int error = GetLastError();
   AppendResult(requestId, ticket > 0, ticket, ticket > 0 ? 0 : error,
                ticket > 0 ? "Pending order placed" : "OrderSend failed");
}

void ExecuteModifyOrder(string requestId, string query)
{
   if(!CanTrade(requestId)) return;
   int ticket = ParamInt(query, "ticket", 0);
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
   {
      AppendResult(requestId, false, ticket, GetLastError(), "Order not found");
      return;
   }
   string symbol = OrderSymbol();
   double price = HasParam(query, "price") ? ParamDouble(query, "price", OrderOpenPrice()) : OrderOpenPrice();
   double sl = HasParam(query, "stopLoss") ? ParamDouble(query, "stopLoss", OrderStopLoss()) : OrderStopLoss();
   double tp = HasParam(query, "takeProfit") ? ParamDouble(query, "takeProfit", OrderTakeProfit()) : OrderTakeProfit();
   datetime expiration = (datetime)(HasParam(query, "expiration")
      ? ParamInt(query, "expiration", (int)OrderExpiration())
      : (int)OrderExpiration());
   ResetLastError();
   bool ok = OrderModify(ticket, NormalizePrice(symbol, price), NormalizePrice(symbol, sl),
                         NormalizePrice(symbol, tp), expiration, clrNONE);
   int error = GetLastError();
   AppendResult(requestId, ok, ticket, ok ? 0 : error, ok ? "Order modified" : "OrderModify failed");
}

void ExecuteClosePosition(string requestId, string query)
{
   if(!CanTrade(requestId)) return;
   int ticket = ParamInt(query, "ticket", 0);
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES) || (OrderType() != OP_BUY && OrderType() != OP_SELL))
   {
      AppendResult(requestId, false, ticket, GetLastError(), "Open position not found");
      return;
   }
   double lots = HasParam(query, "volume") ? ParamDouble(query, "volume", OrderLots()) : OrderLots();
   lots = NormalizeLots(OrderSymbol(), MathMin(lots, OrderLots()));
   double price = MarketInfo(OrderSymbol(), OrderType() == OP_BUY ? MODE_BID : MODE_ASK);
   int slippage = ParamInt(query, "deviation", DefaultSlippagePoints);
   ResetLastError();
   bool ok = OrderClose(ticket, lots, NormalizePrice(OrderSymbol(), price), slippage, clrNONE);
   int error = GetLastError();
   AppendResult(requestId, ok, ticket, ok ? 0 : error, ok ? "Position closed" : "OrderClose failed");
}

void ExecuteCancelOrder(string requestId, string query)
{
   if(!CanTrade(requestId)) return;
   int ticket = ParamInt(query, "ticket", 0);
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES) || OrderType() <= OP_SELL)
   {
      AppendResult(requestId, false, ticket, GetLastError(), "Pending order not found");
      return;
   }
   ResetLastError();
   bool ok = OrderDelete(ticket, clrNONE);
   int error = GetLastError();
   AppendResult(requestId, ok, ticket, ok ? 0 : error, ok ? "Pending order cancelled" : "OrderDelete failed");
}

void ExecuteCloseAll(string requestId, string query)
{
   if(!CanTrade(requestId)) return;
   string symbolFilter = GetParam(query, "symbol");
   bool filterMagic = HasParam(query, "magic");
   int magicFilter = ParamInt(query, "magic", 0);
   int slippage = ParamInt(query, "deviation", DefaultSlippagePoints);
   int completed = 0;
   int failed = 0;
   int lastError = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(StringLen(symbolFilter) > 0 && OrderSymbol() != symbolFilter) continue;
      if(filterMagic && OrderMagicNumber() != magicFilter) continue;
      bool ok = false;
      if(OrderType() == OP_BUY || OrderType() == OP_SELL)
      {
         double price = MarketInfo(OrderSymbol(), OrderType() == OP_BUY ? MODE_BID : MODE_ASK);
         ok = OrderClose(OrderTicket(), OrderLots(), NormalizePrice(OrderSymbol(), price), slippage, clrNONE);
      }
      else
         ok = OrderDelete(OrderTicket(), clrNONE);
      if(ok) completed++;
      else
      {
         failed++;
         lastError = GetLastError();
      }
   }
   AppendResult(requestId, failed == 0, 0, lastError,
                "Completed=" + IntegerToString(completed) + ", failed=" + IntegerToString(failed));
}

void ExecuteCommand(string query)
{
   string requestId = GetParam(query, "requestId");
   string action = GetParam(query, "action");
   if(StringLen(requestId) == 0) return;
   if(action == "place_market") ExecutePlaceMarket(requestId, query);
   else if(action == "place_pending") ExecutePlacePending(requestId, query);
   else if(action == "modify_order") ExecuteModifyOrder(requestId, query);
   else if(action == "close_position") ExecuteClosePosition(requestId, query);
   else if(action == "cancel_order") ExecuteCancelOrder(requestId, query);
   else if(action == "close_all") ExecuteCloseAll(requestId, query);
   else if(action == "refresh") AppendResult(requestId, true, 0, 0, "Snapshot refresh requested");
   else AppendResult(requestId, false, 0, 0, "Unsupported command action");
}

void PollCommands()
{
   string response = "";
   string path = "/v1/commands?terminalId=" + UrlEncode(TerminalId());
   if(!HttpRequest("GET", path, "", response) || StringLen(response) == 0)
      return;
   string lines[];
   int count = StringSplit(response, '\n', lines);
   for(int i = 0; i < count; i++)
   {
      string line = lines[i];
      StringReplace(line, "\r", "");
      if(StringFind(line, "command?") == 0)
         ExecuteCommand(StringSubstr(line, 8));
   }
   g_lastSnapshotAt = 0;
}
