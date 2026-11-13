-module(p49_registro).
-behaviour(gen_server).

-export([start_link/0,
         movimiento/2, incidencia/2,
         movimientos/1, incidencias/1,
         contador/1, contador/2, contadores/0,
         nuevo_token/1, validar_token/1, revocar_token/1,
         estado/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MAX_MOVIMIENTOS, 500).
-define(MAX_INCIDENCIAS, 200).
-define(TOKEN_TTL_SEG, 1800).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

movimiento(Tipo, Datos) ->
    gen_server:cast(?MODULE, {movimiento, Tipo, Datos}).

incidencia(Tipo, Datos) ->
    gen_server:cast(?MODULE, {incidencia, Tipo, Datos}).

movimientos(Limite) ->
    gen_server:call(?MODULE, {movimientos, Limite}).

incidencias(Limite) ->
    gen_server:call(?MODULE, {incidencias, Limite}).

contador(Clave) ->
    gen_server:call(?MODULE, {contador, Clave}).

contador(Clave, Delta) ->
    gen_server:call(?MODULE, {contador, Clave, Delta}).

contadores() ->
    gen_server:call(?MODULE, contadores).

nuevo_token(Pin) ->
    gen_server:call(?MODULE, {nuevo_token, Pin}).

validar_token(Token) ->
    gen_server:call(?MODULE, {validar_token, Token}).

revocar_token(Token) ->
    gen_server:call(?MODULE, {revocar_token, Token}).

estado() ->
    gen_server:call(?MODULE, estado).

init([]) ->
    logger:info("registro iniciado", #{modulo => ?MODULE,
                                        proyecto => p49_estacionamiento_del_campus}),
    erlang:send_after(300000, self(), limpiar_tokens),
    {ok, #{inicio => p49_util:ahora_seg(),
           movimientos => [],
           incidencias => [],
           contadores => contadores_iniciales(),
           tokens => #{}}}.

contadores_iniciales() ->
    #{solicitudes => 0, reservas => 0, confirmadas => 0, canceladas => 0,
      entradas => 0, salidas => 0,
      rechazos => 0, sesiones_admin => 0, accesos_denegados => 0,
      simulaciones => 0, simulaciones_solicitudes => 0,
      simulaciones_rechazadas => 0, fuera_servicio_manual => 0,
      cierres_zona => 0, aperturas_zona => 0}.

handle_call({contador, Clave}, _From, State) ->
    {reply, maps:get(Clave, maps:get(contadores, State), 0), State};
handle_call({contador, Clave, Delta}, _From, State) ->
    Contadores = maps:get(contadores, State),
    Nuevo = maps:put(Clave, maps:get(Clave, Contadores, 0) + Delta, Contadores),
    {reply, ok, State#{contadores := Nuevo}};
handle_call(contadores, _From, State) ->
    {reply, maps:get(contadores, State), State};
handle_call({movimientos, Limite}, _From, State) ->
    {reply, p49_util:recortar(maps:get(movimientos, State), Limite), State};
handle_call({incidencias, Limite}, _From, State) ->
    {reply, p49_util:recortar(maps:get(incidencias, State), Limite), State};
handle_call({nuevo_token, Pin}, _From, State) ->
    PinEsperado = p49_config:admin_pin(),
    case p49_util:bin(Pin) =:= PinEsperado of
        true ->
            Token = binary:encode_hex(crypto:strong_rand_bytes(24)),
            Expira = p49_util:ahora_seg() + ?TOKEN_TTL_SEG,
            Tokens = maps:put(Token, Expira, maps:get(tokens, State)),
            Contadores = inc(State, sesiones_admin),
            {reply, {ok, Token, Expira}, State#{tokens := Tokens,
                                                contadores := Contadores}};
        false ->
            Contadores = inc(State, accesos_denegados),
            logger:warning("intento de acceso administrativo con PIN invalido",
                           #{modulo => ?MODULE}),
            {reply, {error, pin_invalido}, State#{contadores := Contadores}}
    end;
handle_call({validar_token, Token}, _From, State) ->
    Ahora = p49_util:ahora_seg(),
    Tokens = maps:get(tokens, State),
    case maps:find(Token, Tokens) of
        {ok, Expira} when Expira > Ahora ->
            {reply, true, State};
        _ ->
            {reply, false, State#{tokens := maps:remove(Token, Tokens)}}
    end;
handle_call({revocar_token, Token}, _From, State) ->
    Tokens = maps:remove(Token, maps:get(tokens, State)),
    {reply, ok, State#{tokens := Tokens}};
handle_call(estado, _From, State) ->
    Ahora = p49_util:ahora_seg(),
    {reply, #{inicio => maps:get(inicio, State),
              uptime_seg => Ahora - maps:get(inicio, State),
              contadores => maps:get(contadores, State),
              movimientos => length(maps:get(movimientos, State)),
              incidencias => length(maps:get(incidencias, State)),
              sesiones_activas => map_size(maps:get(tokens, State))},
     State};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({movimiento, Tipo, Datos}, State) ->
    Entrada = #{id => p49_util:id("mov"), tipo => Tipo,
                datos => Datos, ts => p49_util:ahora_seg()},
    Movs = p49_util:recortar([Entrada | maps:get(movimientos, State)],
                             ?MAX_MOVIMIENTOS),
    {noreply, State#{movimientos := Movs}};
handle_cast({incidencia, Tipo, Datos}, State) ->
    Entrada = #{id => p49_util:id("inc"), tipo => Tipo,
                datos => Datos, ts => p49_util:ahora_seg()},
    Ings = p49_util:recortar([Entrada | maps:get(incidencias, State)],
                            ?MAX_INCIDENCIAS),
    logger:warning("incidencia registrada: ~p", [Tipo],
                   #{modulo => ?MODULE, datos => Datos}),
    {noreply, State#{incidencias := Ings}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(limpiar_tokens, State) ->
    Ahora = p49_util:ahora_seg(),
    Tokens = maps:filter(fun(_T, Expira) -> Expira > Ahora end,
                         maps:get(tokens, State)),
    erlang:send_after(300000, self(), limpiar_tokens),
    {noreply, State#{tokens := Tokens}};
handle_info(_Info, State) ->
    {noreply, State}.

inc(State, Nombre) ->
    Contadores = maps:get(contadores, State),
    maps:put(Nombre, maps:get(Nombre, Contadores, 0) + 1, Contadores).
