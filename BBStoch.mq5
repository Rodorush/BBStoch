//+------------------------------------------------------------------+
//|                                             BBStoch (v.1.01).mq5 |
//|                                       Rodolfo Pereira de Andrade |
//|                                    https://rodorush.blogspot.com |
//+------------------------------------------------------------------+
#property copyright "Rodolfo Pereira de Andrade"
#property link      "https://rodorush.blogspot.com"
#property version   "1.01"

bool contaHedge;
bool squeezeTrade = false; // Indica se a operação foi aberta em modo Squeeze
double lote1, lote2;
double bbUpper[], bbMiddle[], bbLower[];   // Buffers para Bollinger Bands
double stoch[];                            // Buffer para Estocástico
double precoEntrada, precoStop;
double precoTarget;
double tickSize;
double tickValue;
double spread;
double stopInit;
ENUM_TIMEFRAMES periodo;
int bbHandle, stochHandle;  // Handles dos indicadores
int sinal;

MqlRates rates[];
MqlTick lastTick;
MqlTradeRequest myRequest = {};
MqlTradeResult myResult = {};

string robot = "BBStoch 1.01"; // Nome do EA
string simbolo;

//-----------------------------------------------------
// Parâmetros
//-----------------------------------------------------
input group "Parâmetros"
input double meta           = 0;      // Meta diária em moeda. Se 0 não usa
input double breakEvenFibo  = 161.8;  // Gatilho para BreakEven em porcentagem de Fibo
input double breakEvenMoeda = 0;      // Gatilho para BreakEven em valor de moeda
input double breakEvenGap   = 5;      // Valor do BreakEven em pontos da entrada real

input group "Squeeze Trades"
input bool useSqueezeTrades = false; // Operar em Modo Squeeze? 
input int velaSqueeze       = 1;     // Vela que considera o Squeeze
input double squeeze        = 1.00;  // Porcentagem máxima de um squeeze para operar um breakout

input group "Configurações de Stop"
input double stopInicial  = 2000.0; // Stop inicial em pontos
input bool usePhantomStop = true;   // Utiliza Stop Fantasma?

input group "Alvos em Fibo (%)"
input double riscoMoeda    = 0;     // Risco em moeda. Se 0 não usa
input double riscoPorCento = 0;     // Risco em %
input double alvoFibo1     = 200;   // Alvo 1 em porcentagem de Fibo
input double Lote1         = 0.01;  // Lotes para Alvo 1
input double alvoFibo2     = 200;   // Alvo 2 em porcentagem de Fibo
input double Lote2         = 0;     // Lotes para Alvo 2

// -------------------------
// Novos alvos em Moeda
// -------------------------
input group "Alvos em Moeda ( $ / € / ... )"
// Se alvoMoeda1 for 10, por exemplo, significa que o TP do 1º alvo deve realizar 10 da moeda da conta
input double alvoMoeda1 = 0; 
input double alvoMoeda2 = 0;

//-----------------------------------------------------
// Configurações de Bollinger Bands
//-----------------------------------------------------
input group "Bollinger Bands"
input int    bb_period         = 20;   
input int    bb_shift          = 0;    
input double bb_deviation      = 2.0;  
input ENUM_APPLIED_PRICE bb_applied_price = PRICE_CLOSE; 

//-----------------------------------------------------
// Configurações de Estocástico Lento
//-----------------------------------------------------
input group "Estocástico Lento"
input int Kperiod                        = 14; 
input int Dperiod                        = 3; 
input int slowing                        = 3; 
input ENUM_MA_METHOD ma_method           = MODE_SMA; 
input ENUM_STO_PRICE price_field         = STO_LOWHIGH; 

//-----------------------------------------------------
// Níveis Estocástico
//-----------------------------------------------------
input group "Níveis Estocástico"
input int sc = 80; // Sobrecompra
input int sv = 20; // Sobrevenda

//-----------------------------------------------------
// Horário de Funcionamento
//-----------------------------------------------------
input group "Horário de Funcionamento"
input int  startHour     = 0;    // Hora de início dos trades
sinput int startMinutes  = 0;    // Minutos de início (fora da otimização)
input int  stopHour      = 23;   // Hora de interrupção
sinput int stopMinutes   = 59;   // Minutos de interrupção (fora da otimização)

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Verifica restrição de lote mínimo 0.01
   double minLot = 0;
   if(!SymbolInfoDouble(ChartSymbol(0),SYMBOL_VOLUME_MIN,minLot))
   {
      Print("Não foi possível ler o lote mínimo do símbolo. Encerrando EA...");
      ExpertRemove();
      return(INIT_FAILED);
   }
   if(minLot > 0.01)
   {
      Print("AVISO: A corretora não permite lote de 0.01. Lote mínimo permitido = ", 
            DoubleToString(minLot,_Digits));
      Print("EA será removido devido à restrição de lote mínimo.");
      ExpertRemove();
      return(INIT_FAILED);
   }

   if(startHour > stopHour) return(INIT_PARAMETERS_INCORRECT);

   // Verifica tipo de conta (Hedge ou Netting)
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      contaHedge = true;
      Print("Robô trabalhando em modo Hedge.");
   }
   else
   {
      contaHedge = false;
      Print("Robô trabalhando em modo Netting.");
   }
   stopInit = stopInicial;
   
   ArraySetAsSeries(bbUpper,true);
   ArraySetAsSeries(bbMiddle,true);
   ArraySetAsSeries(bbLower,true);
   ArraySetAsSeries(stoch,true);
   ArraySetAsSeries(rates,true);

   simbolo  = ChartSymbol(0);
   periodo  = ChartPeriod(0);
   tickSize = SymbolInfoDouble(simbolo,SYMBOL_TRADE_TICK_SIZE);
   tickValue= SymbolInfoDouble(simbolo,SYMBOL_TRADE_TICK_VALUE);
   spread   = SymbolInfoInteger(Symbol(),SYMBOL_SPREAD)*tickSize;
              
   SymbolInfoTick(simbolo,lastTick);
   CopyRates(simbolo, periodo, 0, 3, rates);

   myRequest.symbol       = simbolo;
   myRequest.deviation    = 0;
   myRequest.type_filling = ORDER_FILLING_RETURN;
   myRequest.type_time    = ORDER_TIME_DAY;
   myRequest.comment      = robot;
   
   // Identificando valores de ordens manuais abertas para gestão
   if(PositionSelect(simbolo))
   {
      precoEntrada = GlobalVariableGet("precoEntrada"+simbolo);
      precoStop    = GlobalVariableGet("precoStop"+simbolo);
      if(precoEntrada == 0)
      {
         MessageBox("Não há preço de Entrada definido p/ a posição ativa. Informe e tente novamente.");
         ExpertRemove();
      }
      else if(precoStop == 0)
      {
         MessageBox("Não há preço de Stop definido p/ a posição ativa. Informe e tente novamente.");
         ExpertRemove();
      }
      else if(PositionGetDouble(POSITION_SL) == 0)
      {
         MessageBox("Não há StopLoss definido p/ a posição ativa. Crie esse Stop e tente novamente.");
         ExpertRemove();
      }
      
      if(usePhantomStop)
      {
         StopFantasma((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) 
                       ? precoStop - tickSize
                       : precoStop + tickSize);
      }
      else
      {
         double slAtual = PositionGetDouble(POSITION_SL);
         if(slAtual == 0)
         {
            MqlTradeRequest reqSL = {};
            MqlTradeResult resSL  = {};
            reqSL.action   = TRADE_ACTION_SLTP;
            reqSL.symbol   = _Symbol;
            reqSL.position = PositionGetInteger(POSITION_TICKET);
            reqSL.sl       = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) 
                             ? precoStop - tickSize
                             : precoStop + tickSize + spread;

            if(!OrderSend(reqSL, resSL))
               Print("Falha ao inserir SL real para posição manual. Erro=", GetLastError());         
         }
      }
   }
   else
   {
      precoEntrada = 0;
      precoStop    = 0;
      GlobalVariableSet("precoEntrada"+simbolo,0);
      GlobalVariableSet("precoStop"+simbolo,0);
   }
   
   // Inicializa indicadores
   bbHandle = iBands(simbolo, periodo, bb_period, bb_shift, bb_deviation, bb_applied_price);
   stochHandle = iStochastic(simbolo, periodo, Kperiod, Dperiod, slowing, ma_method, price_field);

   // -----------------------------------------------------------
   //  Verifica se o usuário preencheu "alvoFibo" e "alvoMoeda"
   //  ao mesmo tempo. Se sim, aborta a inicialização.
   // -----------------------------------------------------------
   if((alvoFibo1 > 0 && alvoMoeda1 > 0) ||
      (alvoFibo2 > 0 && alvoMoeda2 > 0))
   {
      MessageBox("Não é permitido definir Alvo em Fibo e Alvo em Moeda ao mesmo tempo.\n"+
                 "Zere um deles antes de prosseguir.", 
                 "Parâmetros Inválidos", MB_OK|MB_ICONERROR);
      ExpertRemove();
      return(INIT_FAILED);
   }
   
   // -----------------------------------------------------------
   //  Verifica se o usuário preencheu "breakEvenFibo" e "breakEvenMoeda"
   //  ao mesmo tempo. Se sim, aborta a inicialização.
   // -----------------------------------------------------------
   if(breakEvenFibo > 0 && breakEvenMoeda > 0)
   {
      MessageBox("Não é permitido definir BreakEven em Fibo e em Moeda ao mesmo tempo.\n"+
               "Zere um deles antes de prosseguir.", 
               "Parâmetros Inválidos", MB_OK|MB_ICONERROR);
      ExpertRemove();
      return(INIT_FAILED);
   }
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   int bars = Bars(simbolo, periodo);
   SymbolInfoTick(simbolo,lastTick);
   CopyRates(simbolo, periodo, 0, 3, rates);

   // Se Netting, respeita janelas
   if(!contaHedge)
   {
      if(!TimeSession(startHour,startMinutes,stopHour,stopMinutes,TimeCurrent()))
      {
         DeletaOrdem();
         FechaPosicao();
         DeletaAlvo();
         Comment("Fora do horário de trabalho. EA dormindo...");
      }
      else
      {
         Comment("");
      }
   }
   
   // Se não tem posição e bateu meta, para
   if(PositionsTotal() == 0)
      if(BateuMeta()) return;

   // A cada nova vela
   if(NovaVela(bars))
   {
      IndBuffers();

      // Se já existe posição aberta
      if(PositionSelect(simbolo))
      {
         if(usePhantomStop)
         {
            // Ajusta Stop caso o preço chegue a violar Stop fantasma
            if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && rates[1].close < precoStop) ||
               (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && rates[1].close > precoStop))
            {
               if(contaHedge) ColocaStopHedge(); 
               else ColocaStop();
            }
         }
         
         if(squeezeTrade)
         {
            TrailingStopSqueezeHedge();
         }
      }
      else
      {
         // Não existe posição
         if(Sinal())
         {
            if(contaHedge) ColocaOrdemHedge(); 
            else ColocaOrdem();
         }
         else
         {
            if(contaHedge) DeletaOrdemHedge(); 
            else DeletaOrdem();
         }
      }
   }

   // Se existe posição, verifica breakeven e alvos
   if(contaHedge)
   {
      if(PositionSelect(simbolo)) 
         BreakevenHedge();
   }
   else
   {
      if(PositionSelect(simbolo))
      {
         Breakeven();
         // Se não há ordens de alvo e volume está inteiro
         if(OrdersTotal() == 0 && PositionGetDouble(POSITION_VOLUME) == (lote1 + lote2))
            ColocaAlvo();  // <-- Ajustada para lidar com alvo Fibo ou Moeda
      }
      else
      {
         DeletaAlvo(); 
      }
   }
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
   if(contaHedge) DeletaOrdemHedge(); 
   else DeletaOrdem();

   GlobalVariableSet("precoEntrada"+simbolo,precoEntrada);
   GlobalVariableSet("precoStop"+simbolo,   precoStop);
   MessageBox("EA removido com sucesso!",NULL,MB_OK);
}

//+------------------------------------------------------------------+
//| Funções de apoio                                                 |
//+------------------------------------------------------------------+
void IndBuffers()
{
   // Copia buffers das Bollinger Bands e do Estocástico
   CopyBuffer(bbHandle, 0, 0, 3, bbMiddle);
   CopyBuffer(bbHandle, 1, 0, 3, bbUpper);
   CopyBuffer(bbHandle, 2, 0, 3, bbLower);
   CopyBuffer(stochHandle, 0, 0, 3, stoch);
}

//+------------------------------------------------------------------+
//| Sinal de entrada                                                 |
//+------------------------------------------------------------------+
bool Sinal()
{
   sinal = 0;

   if(SqueezeMode())
   {
      if(rates[1].close > bbUpper[1])
      {
         sinal = 2;
      }
      else if(rates[1].close < bbLower[1])
      {
         sinal = -2;
      }
   }
   else
   {
      if(rates[2].open > bbLower[2] && rates[2].close < bbLower[2] && // Vela de baixa abre acima e fecha abaixo da banda inferior
         rates[1].open < bbLower[1] && rates[1].close > bbLower[1] && // Vela de alta abre abaixo e fecha acima da banda inferior
         stoch[2] < sv) // Estocástico sobrevendido na vela mais antiga
      {
         sinal = 2;
      }

      if(rates[2].open < bbUpper[2] && rates[2].close > bbUpper[2] && // Vela de alta abre abaixo e fecha acima da banda superior
         rates[1].open > bbUpper[1] && rates[1].close < bbUpper[1] && // Vela de baixa abre acima e fecha abaixo da banda superior
         stoch[2] > sc) // Estocástico sobrecomprado na vela mais antiga
      {
         sinal = -2;
      }
   }
   
   return(sinal == -2 || sinal == 2);
}

int InsideBar()
{
   // Se candle anterior "engloba" o candle recente
   if(rates[2].high > rates[1].high && rates[2].low < rates[1].low) 
      return(2);
   return(1);
}

//+------------------------------------------------------------------+
//| Coloca ordem pendente (Netting)                                  |
//+------------------------------------------------------------------+
void ColocaOrdem()
{
   int inside = InsideBar();
   if(OrdersTotal() == 1) DeletaOrdem(); // Remove pendente anterior

   // Prepara variáveis
   precoEntrada = (sinal == 2) ? rates[1].high : rates[1].low;
   GlobalVariableSet("precoEntrada"+simbolo,precoEntrada);

   myRequest.price  = (sinal == 2) ? precoEntrada + tickSize : precoEntrada - tickSize;
   precoStop        = (sinal == 2) ? rates[inside].low : rates[inside].high;
   precoTarget      = (sinal == 2) ? rates[inside].high : rates[inside].low; 
   GlobalVariableSet("precoStop"+simbolo, precoStop);

   if(usePhantomStop)
   {
      StopFantasma((sinal == 2) ? precoStop - tickSize : precoStop + tickSize);
      myRequest.sl = (sinal == 2) ? precoStop - stopInit : precoStop + stopInit;
   }
   else
   {
      myRequest.sl = (sinal == 2) ? precoStop - tickSize : precoStop + tickSize + spread;
   }

   myRequest.type = (sinal == 2) 
                    ? ((myRequest.price >= lastTick.ask) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_BUY_LIMIT)
                    : ((myRequest.price <= lastTick.bid) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_SELL_LIMIT);

   myRequest.action = TRADE_ACTION_PENDING;

   if(riscoMoeda > 0 || riscoPorCento > 0)
      CalculaLotes();
   else
   {
      lote1 = Lote1;
      lote2 = Lote2;
   }

   myRequest.volume = lote1 + lote2;

   bool orderSent;
   do
   {
      orderSent = OrderSend(myRequest,myResult);
      if(!orderSent) Print("Envio de ordem de entrada falhou. Erro = ",GetLastError());
      Sleep(100);
      SymbolInfoTick(simbolo,lastTick);
      CopyRates(simbolo, periodo, 0, 3, rates);
   }
   while(!orderSent);
}

//+------------------------------------------------------------------+
//| Coloca ordem pendente (Hedge)                                    |
//+------------------------------------------------------------------+
void ColocaOrdemHedge()
{
   int inside = InsideBar();
   DeletaOrdemHedge(); // Remove pendente anterior

   precoEntrada = (sinal == 2) ? rates[1].high : rates[1].low; 
   GlobalVariableSet("precoEntrada"+simbolo, precoEntrada);

   myRequest.price  = (sinal == 2) ? precoEntrada + tickSize + spread : precoEntrada - tickSize;
   precoStop        = (sinal == 2) ? rates[inside].low : rates[inside].high; 
   GlobalVariableSet("precoStop"+simbolo, precoStop);

   if(usePhantomStop)
   {
      StopFantasma((sinal == 2) ? precoStop - tickSize : precoStop + tickSize + spread);
      myRequest.sl = (sinal == 2) ? precoStop - stopInit : precoStop + stopInit;
   }
   else
   {
      myRequest.sl = (sinal == 2) ? precoStop - tickSize : precoStop + tickSize + spread;
   }
   
   myRequest.type = (sinal == 2)
                    ? ((myRequest.price >= lastTick.ask) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_BUY_LIMIT)
                    : ((myRequest.price <= lastTick.bid) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_SELL_LIMIT);

   myRequest.action = TRADE_ACTION_PENDING;

   if(riscoMoeda > 0 || riscoPorCento > 0)
      CalculaLotes();
   else
   {
      lote1 = Lote1;
      lote2 = Lote2;
   }

   // --- 1ª ordem (lote1)
   myRequest.volume = lote1;

   // -------------------------------------------------------
   // Ajusta Alvo (TP) levando em conta Fibo OU Moeda
   // -------------------------------------------------------
   double target;
   if(alvoFibo1 > 0)  // Se o alvo 1 for em %Fibo
   {
      target = MathFloor(((rates[inside].high - rates[inside].low)*(alvoFibo1/100.0))/tickSize)*tickSize;
      myRequest.tp = (sinal == 2) ? (rates[1].high + target) 
                                  : (rates[1].low  - target); 
   }
   else if(alvoMoeda1 > 0) // Se o alvo 1 for em Moeda
   {
      myRequest.tp = CalculaTpMoeda((sinal == 2), precoEntrada, lote1, alvoMoeda1);
   }
   else
   {
      myRequest.tp = 0; // Nenhum alvo definido
   }
   
   if(SqueezeMode())
   {
      myRequest.tp = 0;
      squeezeTrade = true;
   }
   else
   {
      squeezeTrade = false;
   }

   bool orderSent;
   do
   {
      orderSent = OrderSend(myRequest,myResult);
      if(!orderSent) Print("Envio de ordem (1ª posição) falhou. Erro = ",GetLastError());
      Sleep(100);
      SymbolInfoTick(simbolo,lastTick);
      CopyRates(simbolo, periodo, 0, 3, rates);
   }
   while(!orderSent);

   // --- 2ª ordem (lote2) só se lote2>0
   if(lote2 > 0)
   {
      myRequest.volume = lote2;

      if(alvoFibo2 > 0)
      {
         target = MathFloor(((rates[inside].high - rates[inside].low)*(alvoFibo2/100.0))/tickSize)*tickSize;
         myRequest.tp = (sinal == 2) ? (rates[1].high + target) 
                                     : (rates[1].low  - target);
      }
      else if(alvoMoeda2 > 0)
      {
         myRequest.tp = CalculaTpMoeda((sinal == 2), precoEntrada, lote2, alvoMoeda2);
      }
      else
      {
         myRequest.tp = 0; 
      }
      
      if(SqueezeMode())
      {
         myRequest.tp = 0;
         squeezeTrade = true;
      }
      else
      {
         squeezeTrade = false;
      }
      
      do
      {
         orderSent = OrderSend(myRequest,myResult);
         if(!orderSent) Print("Envio de ordem (2ª posição) falhou. Erro = ",GetLastError());
         Sleep(100);
         SymbolInfoTick(simbolo,lastTick);
         CopyRates(simbolo, periodo, 0, 3, rates);
      }
      while(!orderSent);
   }
}

//+------------------------------------------------------------------+
//| Coloca Alvo(s) no modo Netting                                   |
//+------------------------------------------------------------------+
void ColocaAlvo()
{
   // Só faz sentido colocar ordens-limite se houve volume (lote1 ou lote2)
   int inside = InsideBar();
   long positionType = PositionGetInteger(POSITION_TYPE);

   myRequest.action = TRADE_ACTION_PENDING;
   myRequest.sl     = 0;
   myRequest.type   = (positionType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_BUY_LIMIT;

   // --- Alvo 1 (se lote1>0)
   if(lote1 > 0)
   {
      double targetPrice1 = 0.0;
      
      // Se estiver usando Fibo
      if(alvoFibo1 > 0)
      {
         double target1 = MathFloor(((rates[inside].high - rates[inside].low)*(alvoFibo1/100.0))/tickSize)*tickSize;
         targetPrice1 = (positionType == POSITION_TYPE_BUY) 
                        ? (rates[1].high + target1) 
                        : (rates[1].low  - target1);
      }
      // Se estiver usando Moeda
      else if(alvoMoeda1 > 0)
      {
         bool isBuy = (positionType == POSITION_TYPE_BUY);
         double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         targetPrice1 = CalculaTpMoeda(isBuy, entryPrice, lote1, alvoMoeda1);
      }
      
      if(targetPrice1 > 0)  // Se calculado
      {
         myRequest.volume= lote1;
         myRequest.price = targetPrice1;
         Print("Colocando Alvo 1...");
         if(!OrderSend(myRequest,myResult)) 
            Print("Envio de ordem Alvo 1 falhou. Erro = ",GetLastError());
      }
   }

   // --- Alvo 2 (se lote2>0)
   if(lote2 > 0)
   {
      double targetPrice2 = 0.0;

      // Se estiver usando Fibo
      if(alvoFibo2 > 0)
      {
         double target2 = MathFloor(((rates[inside].high - rates[inside].low)*(alvoFibo2/100.0))/tickSize)*tickSize;
         targetPrice2 = (positionType == POSITION_TYPE_BUY) 
                        ? (rates[1].high + target2) 
                        : (rates[1].low  - target2);
      }
      // Se estiver usando Moeda
      else if(alvoMoeda2 > 0)
      {
         bool isBuy = (positionType == POSITION_TYPE_BUY);
         double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         targetPrice2 = CalculaTpMoeda(isBuy, entryPrice, lote2, alvoMoeda2);
      }

      if(targetPrice2 > 0)
      {
         myRequest.volume= lote2;
         myRequest.price = targetPrice2;
         Print("Colocando Alvo 2...");
         if(!OrderSend(myRequest,myResult)) 
            Print("Envio de ordem Alvo 2 falhou. Erro = ",GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Coloca Stop (Netting)                                            |
//+------------------------------------------------------------------+
void ColocaStop()
{
   myRequest.action = TRADE_ACTION_SLTP;
   myRequest.sl = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) 
                  ? rates[1].low  - tickSize 
                  : rates[1].high + tickSize + spread;

   if(!OrderSend(myRequest,myResult)) 
      Print("Inclusão de Stop no Trade falhou. Erro = ",GetLastError());
   ObjectDelete(0,"StopFantasma");
}

//+------------------------------------------------------------------+
//| Coloca Stop (Hedge)                                              |
//+------------------------------------------------------------------+
void ColocaStopHedge()
{
   myRequest.action = TRADE_ACTION_SLTP;
   myRequest.sl = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) 
                  ? rates[1].low  - tickSize 
                  : rates[1].high + tickSize + spread;

   int positionsTotal = PositionsTotal();
   for(int i = 0; i < positionsTotal; i++)
   {
      if(PositionGetSymbol(i) == simbolo)
      {
         myRequest.position = PositionGetTicket(i);
         if(!OrderSend(myRequest,myResult)) 
            Print("Inclusão de Stop no Trade ",(i+1)," falhou. Erro = ",GetLastError());
      }
   }
   ObjectDelete(0,"StopFantasma");
}

//+------------------------------------------------------------------+
//| Breakeven (Netting)                                              |
//+------------------------------------------------------------------+
void Breakeven()
{
   // Pega dados da posição atual
   double stopLoss     = PositionGetDouble(POSITION_SL);
   double entradaReal  = PositionGetDouble(POSITION_PRICE_OPEN);
   double floatingProfit = PositionGetDouble(POSITION_PROFIT);
   long   positionType = PositionGetInteger(POSITION_TYPE);

   // Se já moveu SL para >= entrada, não faz nada
   if(positionType == POSITION_TYPE_BUY && stopLoss >= entradaReal) return;
   if(positionType == POSITION_TYPE_SELL && stopLoss <= entradaReal) return;

   double novoStop = 0.0;

   // --------------------------------------------------------------------------------
   // 1) Se o usuário definiu BreakEvenFibo (exatamente como no código original)
   // --------------------------------------------------------------------------------
   if(breakEvenFibo > 0)
   {
      // Cálculo do 'target' baseado na distância entre precoStop e precoTarget
      double target = MathFloor((MathAbs(precoTarget - precoStop)*(breakEvenFibo/100.0))/tickSize)*tickSize;

      if(positionType == POSITION_TYPE_BUY)
      {
         // Só move se o candle atual (rates[0]) subiu além do precoEntrada + target
         if(rates[0].high >= precoEntrada + target)
            novoStop = entradaReal + breakEvenGap; 
      }
      else // SELL
      {
         if(rates[0].low <= precoEntrada - target)
            novoStop = entradaReal - breakEvenGap; 
      }
   }
   // --------------------------------------------------------------------------------
   // 2) Se o usuário definiu BreakEvenMoeda
   // --------------------------------------------------------------------------------
   else if(breakEvenMoeda > 0)
   {
      // Se o lucro flutuante atual é >= breakEvenMoeda, move SL
      if(floatingProfit >= breakEvenMoeda)
      {
         if(positionType == POSITION_TYPE_BUY)
            novoStop = entradaReal + breakEvenGap;
         else
            novoStop = entradaReal - breakEvenGap;
      }
   }

   // Se não definimos breakEvenFibo nem breakEvenMoeda, ou
   // se as condições acima não foram atendidas, sai
   if(novoStop == 0.0) return;

   // ---------------------------------------------------------------------
   // Envia ordem para ajustar StopLoss
   // ---------------------------------------------------------------------
   myRequest.action   = TRADE_ACTION_SLTP;
   myRequest.position = PositionGetTicket(0); // Netting => só 1 posição do símbolo

   myRequest.sl = novoStop;  // Aplica o stop
   if(!OrderSend(myRequest,myResult))
      Print("Ordem Breakeven falhou. Erro = ",GetLastError());
   else
      Print("Acionando Breakeven (Netting)...");
}

//+------------------------------------------------------------------+ 
//| Breakeven (Hedge)                                                | 
//+------------------------------------------------------------------+ 
void BreakevenHedge()
{
   int totalPos = PositionsTotal();
   for(int i = totalPos - 1; i >= 0; i--)
   {
      // 1) Pega o ticket da i-ésima posição
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      // 2) Seleciona a posição
      if(!PositionSelectByTicket(ticket))
         continue;

      // 3) Verifica se é do nosso símbolo
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      // 4) Lê dados da posição
      double stopLoss       = PositionGetDouble(POSITION_SL);
      double entradaReal    = PositionGetDouble(POSITION_PRICE_OPEN);
      double floatingProfit = PositionGetDouble(POSITION_PROFIT);
      long   positionType   = PositionGetInteger(POSITION_TYPE);

      // 5) Verifica se o SL já está além da entrada
      if(positionType == POSITION_TYPE_BUY  && stopLoss >= entradaReal) continue;
      if(positionType == POSITION_TYPE_SELL && stopLoss <= entradaReal) continue;

      // 6) Aplica lógica do breakeven (seja por Fibo ou por Moeda)
      double novoStop = 0.0;
      // Exemplo: se breakEvenMoeda > 0 e lucro flutuante for suficiente
      if(breakEvenMoeda > 0 && floatingProfit >= breakEvenMoeda)
      {
         if(positionType == POSITION_TYPE_BUY)
            novoStop = entradaReal + breakEvenGap;
         else
            novoStop = entradaReal - breakEvenGap;
      }

      if(novoStop == 0.0)
         continue;

      // 7) Envia ordem de modificação do SL
      myRequest.action   = TRADE_ACTION_SLTP;
      myRequest.position = ticket; // Ticket da posição atual
      myRequest.symbol   = _Symbol;
      myRequest.sl       = novoStop;
      myRequest.tp       = PositionGetDouble(POSITION_TP); // mantêm o TP

      if(!OrderSend(myRequest, myResult))
         Print("Falha ao mover Stop - Ticket=", ticket,
               " Erro=", GetLastError());
      else
         Print("Breakeven Hedge acionado no ticket=", ticket);
   }
}

//+------------------------------------------------------------------+
//| Deleta ordem pendente (Netting)                                  |
//+------------------------------------------------------------------+
void DeletaOrdem()
{
   if(OrdersTotal() == 1)
   {
      myRequest.position = 0;
      myRequest.action   = TRADE_ACTION_REMOVE;
      myRequest.order    = OrderGetTicket(0);
      Print("Deletando Ordem Pendente...");
      if(!OrderSend(myRequest,myResult)) 
         Print("Deleção falhou. Erro = ",GetLastError());
   }

   if(!PositionSelect(simbolo))
   {
      precoEntrada = 0;
      precoStop    = 0;
      ObjectDelete(0,"StopFantasma");
   }
}

//+------------------------------------------------------------------+
//| Deleta ordem pendente (Hedge)                                    |
//+------------------------------------------------------------------+
void DeletaOrdemHedge()
{
   ulong ticket;
   myRequest.position = 0;
   myRequest.action   = TRADE_ACTION_REMOVE;
   int ordersTotal    = OrdersTotal();

   for(int i = ordersTotal-1; i >= 0; i--)
   {
      ticket = OrderGetTicket(i);
      if(OrderGetString(ORDER_SYMBOL) == simbolo)
      {
         myRequest.order = ticket;
         Print("Deletando ordem pendente na posição: ",i);
         if(!OrderSend(myRequest,myResult)) 
            Print("Falha ao deletar ordem ",ticket," Erro = ",GetLastError());
      }
   }

   if(!PositionSelect(simbolo))
   {
      precoEntrada = 0;
      precoStop    = 0;
   }
   ObjectDelete(0,"StopFantasma");
}

//+------------------------------------------------------------------+
//| Deleta alvos se existirem (Netting)                              |
//+------------------------------------------------------------------+
void DeletaAlvo()
{
   int ordersTotal = OrdersTotal();
   for(int i = ordersTotal-1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket > 0)
      {
         long orderType = OrderGetInteger(ORDER_TYPE);
         if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT)
         {
            myRequest.position = 0;
            myRequest.action   = TRADE_ACTION_REMOVE;
            myRequest.order    = orderTicket;
            Print("Deletando Alvo/Limit pendente...");
            if(!OrderSend(myRequest,myResult)) 
               Print("Deleção falhou. Erro = ",GetLastError());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Cálculo de lotes a partir do risco                               |
//+------------------------------------------------------------------+
void CalculaLotes()
{
   double valor = (riscoMoeda > 0) 
                  ? riscoMoeda 
                  : AccountInfoDouble(ACCOUNT_BALANCE)*(riscoPorCento/100);

   double lotes;
   if(contaHedge)
   {
      // Hedge => dividimos em duas ordens
      lotes = valor / (MathAbs(precoEntrada - precoStop)*(tickValue/tickSize));
      lotes = MathRound((lotes/10)*100);
      if(MathMod(lotes,2)!=0) lotes++;
      lote1 = MathMax((lotes/2)*0.1,0.1);
      lote2 = lote1;
   }
   else
   {
      // Netting => abrimos 1 posição com (lote1 + lote2)
      lotes = MathRound(valor / (MathAbs(precoEntrada - precoStop)*(tickValue/tickSize)));
      if(MathMod(lotes,2)!=0) lotes++;
      lote1 = MathMax(lotes/2,1);
      lote2 = lote1;
   }
}

//+------------------------------------------------------------------+
//| Calcula TP para alvo em moeda                                    |
//| Fórmula (para Buy): lucro = (TP - entryPrice)*tickValue/tickSize*volume
//|   => TP = entryPrice + (lucroDesejado / ((tickValue/tickSize)*volume))
//| Para Sell é análogo, mas subtrai em vez de somar.
//+------------------------------------------------------------------+
double CalculaTpMoeda(bool isBuy, double entryPrice, double volume, double alvoMoeda)
{
   if(alvoMoeda <= 0 || volume <= 0) return(0);
   
   double priceDist = alvoMoeda / ((tickValue/tickSize)*volume);
   double tp = (isBuy) ? (entryPrice + priceDist)
                       : (entryPrice - priceDist);
   return tp;
}

//+------------------------------------------------------------------+
//| Desenha linha de "Stop Fantasma"                                 |
//+------------------------------------------------------------------+
void StopFantasma(double sl)
{
   bool falhou = true;
   while(falhou && !IsStopped())
   {
      if(ObjectCreate(0,"StopFantasma",OBJ_HLINE,0,0,sl))
         if(ObjectFind(0,"StopFantasma") == 0)
            if(ObjectSetInteger(0,"StopFantasma",OBJPROP_STYLE,STYLE_DASH))
               if(ObjectGetInteger(0,"StopFantasma",OBJPROP_STYLE) == STYLE_DASH)
                  if(ObjectSetInteger(0,"StopFantasma",OBJPROP_COLOR,clrRed))
                     if(ObjectGetInteger(0,"StopFantasma",OBJPROP_COLOR) == clrRed)
                     {
                        ChartRedraw(0);
                        falhou = false;
                     }
   }
}

//+------------------------------------------------------------------+
//| Verifica se a meta diária foi alcançada                          |
//+------------------------------------------------------------------+
bool BateuMeta()
{
   double saldo = 0;
   datetime now   = TimeCurrent();
   datetime today = (now / 86400) * 86400; // Início do dia em UnixTime

   if(meta == 0) return(false);

   if(HistorySelect(today,now))
   {
      int historyDealsTotal = HistoryDealsTotal();
      for(int i = historyDealsTotal; i > 0; i--)
         saldo += HistoryDealGetDouble(HistoryDealGetTicket(i-1),DEAL_PROFIT);
   }
   else
      Print("Erro ao obter histórico de ordens e trades!");

   if(saldo > meta)
   {
      Comment("Meta diária alcançada! CARPE DIEM Guerreiro!");
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Fecha posição do símbolo atual                                   |
//+------------------------------------------------------------------+
void FechaPosicao()
{
   while(PositionSelect(simbolo))
   {
      long positionType      = PositionGetInteger(POSITION_TYPE);
      myRequest.action       = TRADE_ACTION_DEAL;
      myRequest.volume       = PositionGetDouble(POSITION_VOLUME);
      myRequest.type         = (positionType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      myRequest.price        = (positionType == POSITION_TYPE_BUY) ? lastTick.bid : lastTick.ask;
      myRequest.sl           = 0;
      myRequest.tp           = 0;
      myRequest.position     = PositionGetInteger(POSITION_TICKET);

      Print("Fechando posição...");
      if(!OrderSend(myRequest,myResult)) 
         Print("Envio de ordem Fechamento falhou. Erro = ",GetLastError());
      Sleep(100);
      SymbolInfoTick(simbolo,lastTick);
   }   
}

//+------------------------------------------------------------------+
//| Verifica se é uma nova vela                                      |
//+------------------------------------------------------------------+
bool NovaVela(int bars)
{
   static int lastBars = 0;
   if(bars > lastBars)
   {
      lastBars = bars;
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Estamos em um Squeeze?                                           |
//+------------------------------------------------------------------+
bool SqueezeMode()
{
   if(!useSqueezeTrades)
      return(false);
   
   double squeezeValue = ((bbUpper[velaSqueeze] - bbLower[velaSqueeze]) / bbMiddle[velaSqueeze]) * 100;
   string message = "Squeeze = " + DoubleToString(squeezeValue, 2) + "% na posição " + IntegerToString(velaSqueeze);
   
   Comment(message);

   if(squeezeValue < squeeze)
   {
      Comment("Modo Squeeze ativado! " + message);
      return(true);
   }

   return(false);
}

void TrailingStopSqueezeHedge()
{
   if(!useSqueezeTrades)
   {
      Print("TrailingStopSqueezeHedge: Modo Squeeze desabilitado pelo usuário. Saindo...");
      return;
   }   
   
   int totalPos = PositionsTotal();
   
   for(int i = totalPos - 1; i >= 0; i--)
   {
      // Obter o ticket da posição
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      
      // Selecionar a posição pelo ticket
      if(!PositionSelectByTicket(ticket))
         continue;
      
      // Verifica se o símbolo da posição é o mesmo do EA
      string posSymbol = PositionGetString(POSITION_SYMBOL);
      if(posSymbol != simbolo)
         continue;
      
      // Obtém o tipo da posição
      int posType = (int)PositionGetInteger(POSITION_TYPE);
      
      // Obtém o preço de entrada
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      
      // Obtém o stop atual
      double currentStop = PositionGetDouble(POSITION_SL);
      
      // Para operações de COMPRA
      if(posType == POSITION_TYPE_BUY)
      {
         if(bbMiddle[1] > entry)
         {
            double candidateStop = bbMiddle[1];
            if(candidateStop > currentStop)
            {
               myRequest.action   = TRADE_ACTION_SLTP;
               myRequest.position = ticket;
               myRequest.sl       = candidateStop;
               if(OrderSend(myRequest, myResult))
                  Print("Trailing Stop (COMPRA) atualizado para ticket ", ticket, " para ", candidateStop);
               else
                  Print("Erro ao atualizar Trailing Stop (COMPRA) no ticket ", ticket, ": ", GetLastError());
            }
         }
      }
      // Para operações de VENDA
      else if(posType == POSITION_TYPE_SELL)
      {
         if(bbMiddle[1] < entry)
         {
            double candidateStop = bbMiddle[1];
            if(candidateStop < currentStop)
            {
               myRequest.action   = TRADE_ACTION_SLTP;
               myRequest.position = ticket;
               myRequest.sl       = candidateStop + spread;
               if(OrderSend(myRequest, myResult))
                  Print("Trailing Stop (VENDA) atualizado para ticket ", ticket, " para ", candidateStop);
               else
                  Print("Erro ao atualizar Trailing Stop (VENDA) no ticket ", ticket, ": ", GetLastError());
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Verifica se estamos na janela de trading                         |
//+------------------------------------------------------------------+
bool TimeSession(int aStartHour,int aStartMinute,int aStopHour,int aStopMinute,datetime aTimeCur)
{
   // start/stop em segundos do dia
   int StartTime = 3600*aStartHour + 60*aStartMinute;
   int StopTime  = 3600*aStopHour  + 60*aStopMinute;
   aTimeCur = aTimeCur % 86400; // segundos decorridos do dia

   if(StopTime < StartTime)
   {
      // passa da meia-noite
      if(aTimeCur >= StartTime || aTimeCur < StopTime)
         return(true);
   }
   else
   {
      // dentro do mesmo dia
      if(aTimeCur >= StartTime && aTimeCur < StopTime)
         return(true);
   }
   return(false);
}
//+------------------------------------------------------------------+