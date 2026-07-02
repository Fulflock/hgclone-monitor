//+------------------------------------------------------------------+
//|                                                   HGReporter.mq5 |
//|  Reporter du compte -> dashboard en ligne (GitHub Pages).        |
//|  Toutes les X minutes : compte + positions + ordres + trades     |
//|  fermes -> data/state.json du depot GitHub via l'API.            |
//|  A attacher sur N'IMPORTE QUEL graphique (ex: EURUSD H1),        |
//|  SEPARE de l'EA de trading. Ne trade jamais rien.                |
//|                                                                  |
//|  PREREQUIS MT5 : Outils -> Options -> Expert Advisors ->         |
//|  cocher "Autoriser WebRequest" et ajouter :                      |
//|      https://api.github.com                                      |
//+------------------------------------------------------------------+
#property copyright "HappyGoldQuant - monitoring prive"
#property version   "1.00"
#property strict

input string GithubToken   = "";                  // token GitHub (fine-grained, repo monitor, Contents RW)
input string GithubOwner   = "Fulflock";          // proprietaire du depot
input string GithubRepo    = "hgclone-monitor";   // nom du depot
input string StatePath     = "data/state.json";   // fichier d'etat dans le depot
input int    UpdateMinutes = 60;                  // frequence de mise a jour (minutes)
input int    HistoryDays   = 45;                  // profondeur des trades fermes rapportes
input int    MagicFilter   = 0;                   // 0 = tous les trades ; sinon filtre magic

datetime g_lastSend = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   EventSetTimer(30);
   Print("HGReporter demarre -> https://", GithubOwner, ".github.io/", GithubRepo, "/");
   if(GithubToken == "") Print("ATTENTION : GithubToken vide, aucune mise a jour ne partira");
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason) { EventKillTimer(); }
void OnTimer()
{
   if(GithubToken == "") return;
   if(TimeCurrent() - g_lastSend < UpdateMinutes * 60 && g_lastSend != 0) return;
   if(SendState()) g_lastSend = TimeCurrent();
}

//+------------------------------------------------------------------+
//| Echappe une chaine pour JSON                                     |
//+------------------------------------------------------------------+
string J(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\n", " ");
   StringReplace(s, "\r", " ");
   return(s);
}
string D2(double v) { return(DoubleToString(v, 2)); }
string T2(datetime t) { return(TimeToString(t, TIME_DATE | TIME_SECONDS)); }

//+------------------------------------------------------------------+
//| Historique local d'equity (fichier CSV persistant sur le VPS)    |
//+------------------------------------------------------------------+
string EquityHistoryJson()
{
   // ajoute le point courant
   int h = FileOpen("hg_equity_history.csv", FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return("[]");
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, StringFormat("%s;%s;%s\n", T2(TimeCurrent()),
                   D2(AccountInfoDouble(ACCOUNT_BALANCE)), D2(AccountInfoDouble(ACCOUNT_EQUITY))));
   // relit tout, garde les 1000 derniers points
   FileSeek(h, 0, SEEK_SET);
   string lines[];
   int n = 0;
   while(!FileIsEnding(h))
   {
      string l = FileReadString(h);
      if(StringLen(l) < 5) continue;
      n++;
      ArrayResize(lines, n);
      lines[n - 1] = l;
   }
   FileClose(h);
   int start = MathMax(0, n - 1000);
   string js = "[";
   for(int i = start; i < n; i++)
   {
      string parts[];
      if(StringSplit(lines[i], ';', parts) != 3) continue;
      if(js != "[") js += ",";
      js += StringFormat("{\"t\":\"%s\",\"bal\":%s,\"eq\":%s}", parts[0], parts[1], parts[2]);
   }
   return(js + "]");
}

//+------------------------------------------------------------------+
//| Construit le JSON d'etat complet                                 |
//+------------------------------------------------------------------+
string BuildState()
{
   string js = "{";
   js += "\"updated\":\"" + T2(TimeCurrent()) + "\",";
   js += "\"updated_gmt\":\"" + TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS) + "\",";
   js += "\"account\":{";
   js += "\"login\":" + (string)AccountInfoInteger(ACCOUNT_LOGIN) + ",";
   js += "\"server\":\"" + J(AccountInfoString(ACCOUNT_SERVER)) + "\",";
   js += "\"currency\":\"" + J(AccountInfoString(ACCOUNT_CURRENCY)) + "\",";
   js += "\"balance\":" + D2(AccountInfoDouble(ACCOUNT_BALANCE)) + ",";
   js += "\"equity\":" + D2(AccountInfoDouble(ACCOUNT_EQUITY)) + ",";
   js += "\"floating\":" + D2(AccountInfoDouble(ACCOUNT_PROFIT)) + ",";
   js += "\"margin_free\":" + D2(AccountInfoDouble(ACCOUNT_MARGIN_FREE)) + "},";

   // positions ouvertes
   js += "\"positions\":[";
   bool first = true;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(MagicFilter > 0 && PositionGetInteger(POSITION_MAGIC) != MagicFilter) continue;
      if(!first) js += ",";
      first = false;
      js += "{\"symbol\":\"" + J(PositionGetString(POSITION_SYMBOL)) + "\"";
      js += ",\"type\":\"" + (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "buy" : "sell") + "\"";
      js += ",\"volume\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2);
      js += ",\"entry\":" + D2(PositionGetDouble(POSITION_PRICE_OPEN));
      js += ",\"sl\":" + D2(PositionGetDouble(POSITION_SL));
      js += ",\"tp\":" + D2(PositionGetDouble(POSITION_TP));
      js += ",\"profit\":" + D2(PositionGetDouble(POSITION_PROFIT));
      js += ",\"time\":\"" + T2((datetime)PositionGetInteger(POSITION_TIME)) + "\"}";
   }
   js += "],";

   // ordres en attente
   js += "\"orders\":[";
   first = true;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong tk = OrderGetTicket(i);
      if(!OrderSelect(tk)) continue;
      if(MagicFilter > 0 && OrderGetInteger(ORDER_MAGIC) != MagicFilter) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      string tname = (ot == ORDER_TYPE_BUY_STOP ? "buy stop" : ot == ORDER_TYPE_SELL_STOP ? "sell stop" :
                      ot == ORDER_TYPE_BUY_LIMIT ? "buy limit" : ot == ORDER_TYPE_SELL_LIMIT ? "sell limit" : "autre");
      if(!first) js += ",";
      first = false;
      js += "{\"symbol\":\"" + J(OrderGetString(ORDER_SYMBOL)) + "\"";
      js += ",\"type\":\"" + tname + "\"";
      js += ",\"volume\":" + DoubleToString(OrderGetDouble(ORDER_VOLUME_CURRENT), 2);
      js += ",\"price\":" + D2(OrderGetDouble(ORDER_PRICE_OPEN));
      js += ",\"sl\":" + D2(OrderGetDouble(ORDER_SL));
      js += ",\"tp\":" + D2(OrderGetDouble(ORDER_TP));
      js += ",\"time\":\"" + T2((datetime)OrderGetInteger(ORDER_TIME_SETUP)) + "\"}";
   }
   js += "],";

   // trades fermes (deals de sortie) + stats
   js += "\"deals\":[";
   first = true;
   int nT = 0, nW = 0;
   double sumP = 0, sumWin = 0, sumLoss = 0;
   HistorySelect(TimeCurrent() - HistoryDays * 86400, TimeCurrent());
   int total = HistoryDealsTotal();
   int shown = 0;
   for(int i = total - 1; i >= 0; i--)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(MagicFilter > 0 && HistoryDealGetInteger(tk, DEAL_MAGIC) != MagicFilter) continue;
      double p = HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP)
               + HistoryDealGetDouble(tk, DEAL_COMMISSION);
      nT++; sumP += p;
      if(p > 0) { nW++; sumWin += p; } else sumLoss += -p;
      if(shown < 100)
      {
         if(!first) js += ",";
         first = false;
         shown++;
         // le deal OUT ferme une position : type du deal = sens de cloture -> position inverse
         string side = (HistoryDealGetInteger(tk, DEAL_TYPE) == DEAL_TYPE_BUY ? "sell" : "buy");
         js += "{\"time\":\"" + T2((datetime)HistoryDealGetInteger(tk, DEAL_TIME)) + "\"";
         js += ",\"symbol\":\"" + J(HistoryDealGetString(tk, DEAL_SYMBOL)) + "\"";
         js += ",\"side\":\"" + side + "\"";
         js += ",\"volume\":" + DoubleToString(HistoryDealGetDouble(tk, DEAL_VOLUME), 2);
         js += ",\"price\":" + D2(HistoryDealGetDouble(tk, DEAL_PRICE));
         js += ",\"profit\":" + D2(p);
         js += ",\"comment\":\"" + J(HistoryDealGetString(tk, DEAL_COMMENT)) + "\"}";
      }
   }
   js += "],";
   js += "\"stats\":{\"n\":" + (string)nT + ",\"wins\":" + (string)nW;
   js += ",\"winrate\":" + (nT > 0 ? DoubleToString(100.0 * nW / nT, 1) : "0");
   js += ",\"profit_total\":" + D2(sumP);
   js += ",\"profit_factor\":" + (sumLoss > 0 ? DoubleToString(sumWin / sumLoss, 2) : "0") + "},";
   js += "\"history\":" + EquityHistoryJson();
   js += "}";
   return(js);
}

//+------------------------------------------------------------------+
//| GitHub : recupere le SHA actuel du fichier (necessaire au PUT)   |
//+------------------------------------------------------------------+
string GetFileSha()
{
   string url = "https://api.github.com/repos/" + GithubOwner + "/" + GithubRepo + "/contents/" + StatePath;
   string headers = "Authorization: Bearer " + GithubToken + "\r\n" +
                    "User-Agent: HGReporter\r\nAccept: application/vnd.github+json\r\n";
   char data[], result[];
   string rh;
   int code = WebRequest("GET", url, headers, 15000, data, result, rh);
   if(code != 200) return("");
   string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   int i = StringFind(body, "\"sha\":\"");
   if(i < 0) return("");
   int a = i + 7;
   int b = StringFind(body, "\"", a);
   return(StringSubstr(body, a, b - a));
}

//+------------------------------------------------------------------+
//| Envoie l'etat vers GitHub (PUT contents API)                     |
//+------------------------------------------------------------------+
bool SendState()
{
   string state = BuildState();
   // base64 du contenu
   uchar raw[], b64[], key[];
   StringToCharArray(state, raw, 0, StringLen(state), CP_UTF8);
   if(CryptEncode(CRYPT_BASE64, raw, key, b64) <= 0) { Print("HGReporter: echec base64"); return(false); }
   string content64 = CharArrayToString(b64, 0, WHOLE_ARRAY, CP_UTF8);
   StringReplace(content64, "\n", ""); StringReplace(content64, "\r", "");

   string sha = GetFileSha();
   string body = "{\"message\":\"update " + T2(TimeCurrent()) + "\",\"content\":\"" + content64 + "\"";
   if(sha != "") body += ",\"sha\":\"" + sha + "\"";
   body += "}";

   string url = "https://api.github.com/repos/" + GithubOwner + "/" + GithubRepo + "/contents/" + StatePath;
   string headers = "Authorization: Bearer " + GithubToken + "\r\n" +
                    "User-Agent: HGReporter\r\nAccept: application/vnd.github+json\r\n" +
                    "Content-Type: application/json\r\n";
   char data[], result[];
   string rh;
   StringToCharArray(body, data, 0, StringLen(body), CP_UTF8);
   int code = WebRequest("PUT", url, headers, 20000, data, result, rh);
   if(code == 200 || code == 201)
   {
      Print("HGReporter: dashboard mis a jour (", code, ")");
      return(true);
   }
   Print("HGReporter: ECHEC envoi, code ", code, " — verifier token + whitelist https://api.github.com");
   if(code == -1) Print("  -> WebRequest bloque : Outils/Options/Expert Advisors, ajouter https://api.github.com");
   return(false);
}
//+------------------------------------------------------------------+
