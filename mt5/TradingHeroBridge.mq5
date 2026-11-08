#property strict
#property version   "1.02"
#property description "TradingHero local MT5 trading bridge"

#include <Trade/Trade.mqh>

input string BridgeUrl = "http://127.0.0.1:81";
input string BridgeToken = "";
input int PollIntervalMilliseconds = 300;
input int SnapshotIntervalMilliseconds = 1000;
input int SymbolRefreshIntervalMilliseconds = 30000;
input int RequestTimeoutMilliseconds = 2000;
input int HistoryOrderLimit = 1000;
input bool AllowLiveTrading = false;
input int DefaultSlippagePoints = 20;
input long DefaultMagicNumber = 20261107;

string EA_VERSION = "1.02";
string g_bridgeUrl = "";
string g_bridgeToken = "";
bool g_busy = false;
uint g_lastSnapshotAt = 0;
uint g_lastSymbolsAt = 0;
string g_pendingResults = "";
int g_lastWebRequestError = 0;
uint g_lastWebRequestErrorAt = 0;
int g_previousCloseWarmupIndex = 0;
CTrade g_trade;

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
   g_trade.SetAsyncMode(false);
   int interval = MathMax(200, PollIntervalMilliseconds);
   if(!EventSetMillisecondTimer(interval))
   {
      Print("TradingHeroBridge: cannot start timer, error=", GetLastError());
      return(INIT_FAILED);
   }
   Print("TradingHeroBridge MT5 started. Add ", g_bridgeUrl,
         " to Tools > Options > Expert Advisors > Allow WebRequest.");
   return(INIT_SUCCEEDED);
}

void LoadBridgeConfig()
{
   ResetLastError();
   int handle = FileOpen("TradingHero\\bridge.conf", FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
   {
      Print("TradingHeroBridge: cannot open MQL5\\Files\\TradingHero\\bridge.conf, error=", GetLastError());
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
   if(g_busy) return;
   g_busy = true;
   FlushResults();
   uint now = GetTickCount();
   if(g_lastSnapshotAt == 0 || now - g_lastSnapshotAt >= (uint)MathMax(500, SnapshotIntervalMilliseconds))
   {
      if(SendSnapshot()) g_lastSnapshotAt = now;
   }
   PollCommands();
   FlushResults();
   WarmPreviousClose();
   g_busy = false;
}

string TerminalId()
{
   return(IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "@" + AccountInfoString(ACCOUNT_SERVER));
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
   return(AddField(line, key, IntegerToString(value)));
}

string PositionSideName(ENUM_POSITION_TYPE type)
{
   return(type == POSITION_TYPE_BUY ? "buy" : "sell");
}

string OrderTypeName(ENUM_ORDER_TYPE type)
{
   if(type == ORDER_TYPE_BUY) return("buy");
   if(type == ORDER_TYPE_SELL) return("sell");
   if(type == ORDER_TYPE_BUY_LIMIT) return("buy_limit");
   if(type == ORDER_TYPE_SELL_LIMIT) return("sell_limit");
   if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT) return("buy_stop");
   if(type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_STOP_LIMIT) return("sell_stop");
   return("unknown");
}

string DealTypeName(ENUM_DEAL_TYPE type)
{
   if(type == DEAL_TYPE_BUY) return("buy");
   if(type == DEAL_TYPE_SELL) return("sell");
   if(type == DEAL_TYPE_BALANCE) return("balance");
   if(type == DEAL_TYPE_CREDIT) return("credit");
   return("unknown");
}

string BuildMetaRecord()
{
   string line = "meta?";
   line = AddField(line, "terminalId", TerminalId());
   line = AddField(line, "terminalName", TerminalInfoString(TERMINAL_NAME));
   line = AddInteger(line, "terminalBuild", TerminalInfoInteger(TERMINAL_BUILD));
   line = AddField(line, "eaVersion", EA_VERSION);
   line = AddField(line, "chartSymbol", Symbol());
   return(line);
}

string BuildAccountRecord()
{
   string line = "account?";
   line = AddInteger(line, "login", AccountInfoInteger(ACCOUNT_LOGIN));
   line = AddField(line, "name", AccountInfoString(ACCOUNT_NAME));
   line = AddField(line, "company", AccountInfoString(ACCOUNT_COMPANY));
   line = AddField(line, "server", AccountInfoString(ACCOUNT_SERVER));
   line = AddField(line, "currency", AccountInfoString(ACCOUNT_CURRENCY));
   line = AddInteger(line, "leverage", AccountInfoInteger(ACCOUNT_LEVERAGE));
   line = AddNumber(line, "balance", AccountInfoDouble(ACCOUNT_BALANCE), 2);
   line = AddNumber(line, "equity", AccountInfoDouble(ACCOUNT_EQUITY), 2);
   line = AddNumber(line, "margin", AccountInfoDouble(ACCOUNT_MARGIN), 2);
   line = AddNumber(line, "freeMargin", AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2);
   line = AddNumber(line, "marginLevel", AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), 2);
   line = AddNumber(line, "profit", AccountInfoDouble(ACCOUNT_PROFIT), 2);
   bool tradeAllowed = AllowLiveTrading && TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
      MQLInfoInteger(MQL_TRADE_ALLOWED);
   line = AddInteger(line, "tradeAllowed", tradeAllowed ? 1 : 0);
   line = AddInteger(line, "connected", TerminalInfoInteger(TERMINAL_CONNECTED));
   return(line);
}

string BuildPositionRecord(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return("");
   string line = "position?";
   line = AddInteger(line, "ticket", (long)ticket);
   line = AddField(line, "symbol", PositionGetString(POSITION_SYMBOL));
   line = AddField(line, "side", PositionSideName((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)));
   line = AddNumber(line, "volume", PositionGetDouble(POSITION_VOLUME), 4);
   line = AddNumber(line, "openPrice", PositionGetDouble(POSITION_PRICE_OPEN));
   line = AddNumber(line, "currentPrice", PositionGetDouble(POSITION_PRICE_CURRENT));
   line = AddNumber(line, "stopLoss", PositionGetDouble(POSITION_SL));
   line = AddNumber(line, "takeProfit", PositionGetDouble(POSITION_TP));
   line = AddNumber(line, "profit", PositionGetDouble(POSITION_PROFIT), 2);
   line = AddNumber(line, "swap", PositionGetDouble(POSITION_SWAP), 2);
   line = AddNumber(line, "commission", 0, 2);
   line = AddInteger(line, "magic", PositionGetInteger(POSITION_MAGIC));
   line = AddField(line, "comment", PositionGetString(POSITION_COMMENT));
   line = AddInteger(line, "openedAt", PositionGetInteger(POSITION_TIME));
   return(line);
}

string BuildPendingOrderRecord(ulong ticket)
{
   if(!OrderSelect(ticket)) return("");
   string symbol = OrderGetString(ORDER_SYMBOL);
   string line = "order?";
   line = AddInteger(line, "ticket", (long)ticket);
   line = AddField(line, "symbol", symbol);
   line = AddField(line, "type", OrderTypeName((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)));
   line = AddNumber(line, "volume", OrderGetDouble(ORDER_VOLUME_CURRENT), 4);
   line = AddNumber(line, "openPrice", OrderGetDouble(ORDER_PRICE_OPEN));
   MqlTick tick;
   double currentPrice = SymbolInfoTick(symbol, tick) ? tick.bid : 0;
   line = AddNumber(line, "currentPrice", currentPrice);
   line = AddNumber(line, "stopLoss", OrderGetDouble(ORDER_SL));
   line = AddNumber(line, "takeProfit", OrderGetDouble(ORDER_TP));
   line = AddInteger(line, "expiration", OrderGetInteger(ORDER_TIME_EXPIRATION));
   line = AddInteger(line, "magic", OrderGetInteger(ORDER_MAGIC));
   line = AddField(line, "comment", OrderGetString(ORDER_COMMENT));
   line = AddInteger(line, "openedAt", OrderGetInteger(ORDER_TIME_SETUP));
   return(line);
}

bool HistoryPositionOpenInfo(ulong positionId, double &openPrice, datetime &openedAt, string &typeName)
{
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != positionId) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
      {
         ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal, DEAL_TYPE);
         openPrice = HistoryDealGetDouble(deal, DEAL_PRICE);
         openedAt = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
         typeName = DealTypeName(dealType);
         return(typeName == "buy" || typeName == "sell");
      }
   }
   return(false);
}

string BuildHistoryRecord(ulong deal)
{
   ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal, DEAL_TYPE);
   string typeName = DealTypeName(dealType);
   if(typeName == "unknown") return("");
   datetime closedAt = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   ulong positionId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
   if((typeName == "buy" || typeName == "sell") && entry == DEAL_ENTRY_IN) return("");
   double closePrice = HistoryDealGetDouble(deal, DEAL_PRICE);
   double openPrice = closePrice;
   datetime openedAt = closedAt;
   string positionType = typeName;
   if(typeName == "buy" || typeName == "sell")
      HistoryPositionOpenInfo(positionId, openPrice, openedAt, positionType);
   string line = "history?";
   line = AddInteger(line, "ticket", (long)deal);
   line = AddField(line, "symbol", HistoryDealGetString(deal, DEAL_SYMBOL));
   line = AddField(line, "type", positionType);
   line = AddNumber(line, "volume", HistoryDealGetDouble(deal, DEAL_VOLUME), 4);
   line = AddNumber(line, "openPrice", openPrice);
   line = AddNumber(line, "closePrice", closePrice);
   line = AddNumber(line, "stopLoss", 0);
   line = AddNumber(line, "takeProfit", 0);
   line = AddNumber(line, "profit", HistoryDealGetDouble(deal, DEAL_PROFIT), 2);
   line = AddNumber(line, "swap", HistoryDealGetDouble(deal, DEAL_SWAP), 2);
   line = AddNumber(line, "commission", HistoryDealGetDouble(deal, DEAL_COMMISSION), 2);
   line = AddInteger(line, "magic", HistoryDealGetInteger(deal, DEAL_MAGIC));
   line = AddField(line, "comment", HistoryDealGetString(deal, DEAL_COMMENT));
   line = AddInteger(line, "openedAt", openedAt);
   line = AddInteger(line, "closedAt", closedAt);
   return(line);
}

string SessionTime(datetime value)
{
   MqlDateTime parts;
   TimeToStruct(value, parts);
   return(StringFormat("%02d:%02d", parts.hour, parts.min));
}

string SymbolSessionRanges(string symbol, int dayOfWeek, bool quoteSession)
{
   string ranges = "";
   for(uint index = 0; index < 16; index++)
   {
      datetime sessionFrom = 0;
      datetime sessionTo = 0;
      bool found = quoteSession
         ? SymbolInfoSessionQuote(symbol, (ENUM_DAY_OF_WEEK)dayOfWeek, index, sessionFrom, sessionTo)
         : SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)dayOfWeek, index, sessionFrom, sessionTo);
      if(!found) break;
      if(StringLen(ranges) > 0) ranges += "|";
      ranges += SessionTime(sessionFrom) + "-" + SessionTime(sessionTo);
   }
   return(ranges);
}

string BuildSymbolRecord(string symbol)
{
   string line = "symbol?";
   line = AddField(line, "name", symbol);
   line = AddField(line, "description", SymbolInfoString(symbol, SYMBOL_DESCRIPTION));
   line = AddField(line, "path", SymbolInfoString(symbol, SYMBOL_PATH));
   line = AddInteger(line, "selected", SymbolInfoInteger(symbol, SYMBOL_SELECT));
   line = AddInteger(line, "spread", SymbolInfoInteger(symbol, SYMBOL_SPREAD));
   line = AddInteger(line, "spreadFloat", SymbolInfoInteger(symbol, SYMBOL_SPREAD_FLOAT));
   line = AddInteger(line, "digits", SymbolInfoInteger(symbol, SYMBOL_DIGITS));
   line = AddInteger(line, "stopsLevel", SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL));
   line = AddInteger(line, "freezeLevel", SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL));
   line = AddNumber(line, "contractSize", SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE), 8);
   line = AddField(line, "currencyBase", SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE));
   line = AddField(line, "currencyProfit", SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT));
   line = AddField(line, "currencyMargin", SymbolInfoString(symbol, SYMBOL_CURRENCY_MARGIN));
   line = AddInteger(line, "profitCalculationMode", SymbolInfoInteger(symbol, SYMBOL_TRADE_CALC_MODE));
   line = AddInteger(line, "marginCalculationMode", SymbolInfoInteger(symbol, SYMBOL_TRADE_CALC_MODE));
   line = AddNumber(line, "marginInitial", SymbolInfoDouble(symbol, SYMBOL_MARGIN_INITIAL), 8);
   line = AddNumber(line, "marginMaintenance", SymbolInfoDouble(symbol, SYMBOL_MARGIN_MAINTENANCE), 8);
   line = AddNumber(line, "marginHedged", SymbolInfoDouble(symbol, SYMBOL_MARGIN_HEDGED), 8);
   line = AddNumber(line, "marginRequired", SymbolInfoDouble(symbol, SYMBOL_MARGIN_INITIAL), 8);
   line = AddInteger(line, "tradeMode", SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE));
   line = AddInteger(line, "executionMode", SymbolInfoInteger(symbol, SYMBOL_TRADE_EXEMODE));
   line = AddNumber(line, "minVolume", SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN), 8);
   line = AddNumber(line, "maxVolume", SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX), 8);
   line = AddNumber(line, "volumeStep", SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP), 8);
   line = AddInteger(line, "swapMode", SymbolInfoInteger(symbol, SYMBOL_SWAP_MODE));
   line = AddNumber(line, "swapLong", SymbolInfoDouble(symbol, SYMBOL_SWAP_LONG), 8);
   line = AddNumber(line, "swapShort", SymbolInfoDouble(symbol, SYMBOL_SWAP_SHORT), 8);
   line = AddInteger(line, "swapRollover3Days", SymbolInfoInteger(symbol, SYMBOL_SWAP_ROLLOVER3DAYS));
   for(int day = 0; day < 7; day++)
   {
      line = AddField(line, "quoteSessions" + IntegerToString(day), SymbolSessionRanges(symbol, day, true));
      line = AddField(line, "tradeSessions" + IntegerToString(day), SymbolSessionRanges(symbol, day, false));
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
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return("");
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double high = 0;
   double low = 0;
   SymbolInfoDouble(symbol, SYMBOL_BIDHIGH, high);
   SymbolInfoDouble(symbol, SYMBOL_BIDLOW, low);
   string line = "quote?";
   line = AddField(line, "symbol", symbol);
   line = AddNumber(line, "bid", tick.bid, digits);
   line = AddNumber(line, "ask", tick.ask, digits);
   line = AddNumber(line, "high", high, digits);
   line = AddNumber(line, "low", low, digits);
   line = AddNumber(line, "previousClose", PreviousClose(symbol), digits);
   line = AddInteger(line, "digits", digits);
   line = AddInteger(line, "timestamp", (long)tick.time);
   return(line);
}

string BuildSnapshot(bool includeSymbols)
{
   string body = BuildMetaRecord() + "\n" + BuildAccountRecord();
   int symbolCount = SymbolsTotal(true);
   for(int s = 0; s < symbolCount; s++)
   {
      string symbol = SymbolName(s, true);
      if(StringLen(symbol) == 0) continue;
      string quote = BuildQuoteRecord(symbol);
      if(StringLen(quote) > 0) body += "\n" + quote;
      if(includeSymbols) body += "\n" + BuildSymbolRecord(symbol);
   }
   for(int p = 0; p < PositionsTotal(); p++)
   {
      ulong ticket = PositionGetTicket(p);
      string record = BuildPositionRecord(ticket);
      if(StringLen(record) > 0) body += "\n" + record;
   }
   for(int o = 0; o < OrdersTotal(); o++)
   {
      ulong ticket = OrderGetTicket(o);
      string record = BuildPendingOrderRecord(ticket);
      if(StringLen(record) > 0) body += "\n" + record;
   }
   if(HistorySelect(0, TimeCurrent()))
   {
      int total = HistoryDealsTotal();
      int limit = MathMin(MathMax(0, HistoryOrderLimit), total);
      for(int h = total - 1; h >= total - limit; h--)
      {
         ulong deal = HistoryDealGetTicket(h);
         string record = deal > 0 ? BuildHistoryRecord(deal) : "";
         if(StringLen(record) > 0) body += "\n" + record;
      }
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
   else ArrayResize(data, 0);
   ResetLastError();
   int status = WebRequest(method, url, headers, RequestTimeoutMilliseconds, data, result, resultHeaders);
   if(status == -1)
   {
      int error = GetLastError();
      uint now = GetTickCount();
      if(error != g_lastWebRequestError || now - g_lastWebRequestErrorAt >= 5000)
      {
         if(error == 4014)
            Print("TradingHeroBridge: WebRequest is blocked. Add ", g_bridgeUrl, " to the allowed URL list.");
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
   if(!HttpRequest("POST", "/v1/snapshot", BuildSnapshot(includeSymbols), response)) return(false);
   if(includeSymbols) g_lastSymbolsAt = now;
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
   return(StringFind("&" + query, "&" + key + "=") >= 0);
}

double ParamDouble(string query, string key, double fallback)
{
   string value = GetParam(query, key);
   return(StringLen(value) > 0 ? StringToDouble(value) : fallback);
}

long ParamLong(string query, string key, long fallback)
{
   string value = GetParam(query, key);
   return(StringLen(value) > 0 ? StringToInteger(value) : fallback);
}

double NormalizeLots(string symbol, double lots)
{
   double minimum = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maximum = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   lots = MathMax(minimum, MathMin(maximum, lots));
   lots = MathFloor(lots / step + 0.0000001) * step;
   return(NormalizeDouble(lots, 8));
}

double NormalizePrice(string symbol, double price)
{
   if(price == 0) return(0);
   return(NormalizeDouble(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
}

void AppendResult(string requestId, bool ok, ulong ticket, int errorCode, string message)
{
   string line = "result?";
   line = AddField(line, "requestId", requestId);
   line = AddInteger(line, "ok", ok ? 1 : 0);
   if(ticket > 0) line = AddInteger(line, "ticket", (long)ticket);
   if(errorCode != 0) line = AddInteger(line, "errorCode", errorCode);
   if(StringLen(message) > 0) line = AddField(line, "message", message);
   if(StringLen(g_pendingResults) > 0) g_pendingResults += "\n";
   g_pendingResults += line;
}

void FlushResults()
{
   if(StringLen(g_pendingResults) == 0) return;
   string response = "";
   if(HttpRequest("POST", "/v1/results", g_pendingResults, response)) g_pendingResults = "";
}

bool CanTrade(string requestId)
{
   if(!AllowLiveTrading)
   {
      AppendResult(requestId, false, 0, 0, "EA setting AllowLiveTrading is disabled");
      return(false);
   }
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      AppendResult(requestId, false, 0, 0, "MT5 trading is not allowed or terminal is disconnected");
      return(false);
   }
   return(true);
}

void ConfigureTrade(string query, string fallbackSymbol = "")
{
   g_trade.SetExpertMagicNumber((ulong)ParamLong(query, "magic", DefaultMagicNumber));
   g_trade.SetDeviationInPoints((ulong)ParamLong(query, "deviation", DefaultSlippagePoints));
   string symbol = GetParam(query, "symbol");
   if(StringLen(symbol) == 0) symbol = fallbackSymbol;
   if(StringLen(symbol) > 0) g_trade.SetTypeFillingBySymbol(symbol);
}

void AppendTradeResult(string requestId, bool ok, string successMessage, string failureMessage)
{
   ulong ticket = g_trade.ResultOrder();
   if(ticket == 0) ticket = g_trade.ResultDeal();
   int errorCode = ok ? 0 : (int)g_trade.ResultRetcode();
   string message = ok ? successMessage : failureMessage + ": " + g_trade.ResultRetcodeDescription();
   AppendResult(requestId, ok, ticket, errorCode, message);
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
   if(side != "buy" && side != "sell")
   {
      AppendResult(requestId, false, 0, 0, "Invalid market side");
      return;
   }
   ConfigureTrade(query);
   double volume = NormalizeLots(symbol, ParamDouble(query, "volume", 0));
   double sl = NormalizePrice(symbol, ParamDouble(query, "stopLoss", 0));
   double tp = NormalizePrice(symbol, ParamDouble(query, "takeProfit", 0));
   string comment = GetParam(query, "comment");
   if(StringLen(comment) == 0) comment = "TradingHero";
   bool ok = side == "buy"
      ? g_trade.Buy(volume, symbol, 0, sl, tp, comment)
      : g_trade.Sell(volume, symbol, 0, sl, tp, comment);
   AppendTradeResult(requestId, ok, "Market order placed", "Market order failed");
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
   ConfigureTrade(query);
   double volume = NormalizeLots(symbol, ParamDouble(query, "volume", 0));
   double price = NormalizePrice(symbol, ParamDouble(query, "price", 0));
   double sl = NormalizePrice(symbol, ParamDouble(query, "stopLoss", 0));
   double tp = NormalizePrice(symbol, ParamDouble(query, "takeProfit", 0));
   datetime expiration = (datetime)ParamLong(query, "expiration", 0);
   ENUM_ORDER_TYPE_TIME timeType = expiration > 0 ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
   string comment = GetParam(query, "comment");
   if(StringLen(comment) == 0) comment = "TradingHero";
   bool ok = false;
   if(typeName == "buy_limit") ok = g_trade.BuyLimit(volume, price, symbol, sl, tp, timeType, expiration, comment);
   else if(typeName == "sell_limit") ok = g_trade.SellLimit(volume, price, symbol, sl, tp, timeType, expiration, comment);
   else if(typeName == "buy_stop") ok = g_trade.BuyStop(volume, price, symbol, sl, tp, timeType, expiration, comment);
   else if(typeName == "sell_stop") ok = g_trade.SellStop(volume, price, symbol, sl, tp, timeType, expiration, comment);
   else
   {
      AppendResult(requestId, false, 0, 0, "Invalid pending order type");
      return;
   }
   AppendTradeResult(requestId, ok, "Pending order placed", "Pending order failed");
}

void ExecuteModifyOrder(string requestId, string query)
{
   if(!CanTrade(requestId)) return;
   ulong ticket = (ulong)ParamLong(query, "ticket", 0);
   if(OrderSelect(ticket))
   {
      string symbol = OrderGetString(ORDER_SYMBOL);
      double price = HasParam(query, "price") ? ParamDouble(query, "price", OrderGetDouble(ORDER_PRICE_OPEN)) : OrderGetDouble(ORDER_PRICE_OPEN);
      double sl = HasParam(query, "stopLoss") ? ParamDouble(query, "stopLoss", OrderGetDouble(ORDER_SL)) : OrderGetDouble(ORDER_SL);
      double tp = HasParam(query, "takeProfit") ? ParamDouble(query, "takeProfit", OrderGetDouble(ORDER_TP)) : OrderGetDouble(ORDER_TP);
      datetime expiration = (datetime)(HasParam(query, "expiration")
         ? ParamLong(query, "expiration", OrderGetInteger(ORDER_TIME_EXPIRATION))
         : OrderGetInteger(ORDER_TIME_EXPIRATION));
      ENUM_ORDER_TYPE_TIME timeType = expiration > 0 ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
      bool ok = g_trade.OrderModify(ticket, NormalizePrice(symbol, price), NormalizePrice(symbol, sl),
                                    NormalizePrice(symbol, tp), timeType, expiration, 0);
      AppendTradeResult(requestId, ok, "Order modified", "Order modification failed");
      return;
   }
   if(PositionSelectByTicket(ticket))
   {
      string symbol = PositionGetString(POSITION_SYMBOL);
      double sl = HasParam(query, "stopLoss") ? ParamDouble(query, "stopLoss", PositionGetDouble(POSITION_SL)) : PositionGetDouble(POSITION_SL);
      double tp = HasParam(query, "takeProfit") ? ParamDouble(query, "takeProfit", PositionGetDouble(POSITION_TP)) : PositionGetDouble(POSITION_TP);
      bool ok = g_trade.PositionModify(ticket, NormalizePrice(symbol, sl), NormalizePrice(symbol, tp));
      AppendTradeResult(requestId, ok, "Position modified", "Position modification failed");
      return;
   }
   AppendResult(requestId, false, ticket, GetLastError(), "Order or position not found");
}

void ExecuteClosePosition(string requestId, string query)
{
   if(!CanTrade(requestId)) return;
   ulong ticket = (ulong)ParamLong(query, "ticket", 0);
   if(!PositionSelectByTicket(ticket))
   {
      AppendResult(requestId, false, ticket, GetLastError(), "Open position not found");
      return;
   }
   double currentVolume = PositionGetDouble(POSITION_VOLUME);
   string symbol = PositionGetString(POSITION_SYMBOL);
   ConfigureTrade(query, symbol);
   double requestedVolume = HasParam(query, "volume") ? ParamDouble(query, "volume", currentVolume) : currentVolume;
   bool ok = requestedVolume + 0.0000001 < currentVolume
      ? g_trade.PositionClosePartial(ticket, NormalizeLots(symbol, requestedVolume))
      : g_trade.PositionClose(ticket);
   AppendTradeResult(requestId, ok, "Position closed", "Position close failed");
}

void ExecuteCancelOrder(string requestId, string query)
{
   if(!CanTrade(requestId)) return;
   ulong ticket = (ulong)ParamLong(query, "ticket", 0);
   if(!OrderSelect(ticket))
   {
      AppendResult(requestId, false, ticket, GetLastError(), "Pending order not found");
      return;
   }
   bool ok = g_trade.OrderDelete(ticket);
   AppendTradeResult(requestId, ok, "Pending order cancelled", "Pending order cancellation failed");
}

void ExecuteCloseAll(string requestId, string query)
{
   if(!CanTrade(requestId)) return;
   string symbolFilter = GetParam(query, "symbol");
   bool filterMagic = HasParam(query, "magic");
   long magicFilter = ParamLong(query, "magic", 0);
   int completed = 0;
   int failed = 0;
   int lastError = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(StringLen(symbolFilter) > 0 && OrderGetString(ORDER_SYMBOL) != symbolFilter) continue;
      if(filterMagic && OrderGetInteger(ORDER_MAGIC) != magicFilter) continue;
      if(g_trade.OrderDelete(ticket)) completed++;
      else
      {
         failed++;
         lastError = (int)g_trade.ResultRetcode();
      }
   }
   for(int p = PositionsTotal() - 1; p >= 0; p--)
   {
      ulong ticket = PositionGetTicket(p);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(StringLen(symbolFilter) > 0 && PositionGetString(POSITION_SYMBOL) != symbolFilter) continue;
      if(filterMagic && PositionGetInteger(POSITION_MAGIC) != magicFilter) continue;
      if(g_trade.PositionClose(ticket)) completed++;
      else
      {
         failed++;
         lastError = (int)g_trade.ResultRetcode();
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
   if(!HttpRequest("GET", path, "", response) || StringLen(response) == 0) return;
   string lines[];
   int count = StringSplit(response, '\n', lines);
   for(int i = 0; i < count; i++)
   {
      string line = lines[i];
      StringReplace(line, "\r", "");
      if(StringFind(line, "command?") == 0) ExecuteCommand(StringSubstr(line, 8));
   }
   g_lastSnapshotAt = 0;
}
