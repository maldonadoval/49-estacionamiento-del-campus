-module(p49_cajon).
-behaviour(gen_statem).

-export([start_link/1, estado/1, reservar/5, confirmar/2, cancelar/2,
         liberar/2, ocupar/2, fuera_servicio/2, habilitar/1, restaurar/2]).

-export([callback_mode/0, init/1, handle_event/4]).

-define(TIMEOUT_CONFIRMADA_MS, 14400000).

start_link(Cajon) ->
    gen_statem:start_link(?MODULE, Cajon, []).

estado(Pid) -> gen_statem:call(Pid, estado, 3000).

reservar(Pid, ReservaId, Placa, Edificio, TTL) ->
    gen_statem:call(Pid, {reservar, ReservaId, Placa, Edificio, TTL}, 5000).

confirmar(Pid, ReservaId) ->
    gen_statem:call(Pid, {confirmar, ReservaId}, 5000).

cancelar(Pid, ReservaId) ->
    gen_statem:call(Pid, {cancelar, ReservaId}, 5000).

liberar(Pid, Motivo) ->
    gen_statem:call(Pid, {liberar, Motivo}, 5000).

ocupar(Pid, Placa) ->
    gen_statem:call(Pid, {ocupar, Placa}, 5000).

fuera_servicio(Pid, Motivo) ->
    gen_statem:call(Pid, {fuera_servicio, Motivo}, 5000).

habilitar(Pid) ->
    gen_statem:call(Pid, habilitar, 5000).

restaurar(Pid, Info) ->
    gen_statem:call(Pid, {restaurar, Info}, 5000).

callback_mode() -> handle_event_function.

init(Cajon) ->
    Zona = maps:get(zona, Cajon),
    Numero = maps:get(numero, Cajon),
    {Estado, Reserva, Motivo} = p49_config:estado_inicial(Zona, Numero),
    Data = Cajon#{estado => Estado, reserva => Reserva, motivo => Motivo},
    p49_zona:cajon_listo(Zona, Numero, self()),
    {ok, Estado, Data}.

handle_event({call, From}, estado, State, Data) ->
    {keep_state, Data, [{reply, From, info(State, Data)}]};

handle_event({call, From}, {reservar, ReservaId, Placa, Edificio, TTL},
             libre, Data) ->
    Ahora = p49_util:ahora_seg(),
    Reserva = #{id => ReservaId, placa => Placa, edificio => Edificio,
                creada_en => Ahora, expira_en => Ahora + TTL,
                confirmada => false},
    Nuevo = Data#{reserva := Reserva},
    notificar(Nuevo, reservado),
    Acciones = [{reply, From, {ok, Reserva}},
                {state_timeout, TTL * 1000, expirada}],
    {next_state, reservado, Nuevo, Acciones};
handle_event({call, From}, {reservar, _, _, _, _}, State, Data) ->
    {keep_state, Data, [{reply, From, {error, no_disponible,
                                        #{estado => State}}}]};

handle_event({call, From}, {confirmar, ReservaId}, reservado,
             #{reserva := Reserva} = Data) ->
    case maps:get(id, Reserva, undefined) of
        ReservaId ->
            case maps:get(confirmada, Reserva, false) of
                true ->
                    {keep_state, Data, [{reply, From, ok}]};
                false ->
                    Ahora = p49_util:ahora_seg(),
                    Nueva = Reserva#{confirmada := true,
                                     expira_en := Ahora + 14400,
                                     confirmada_en => Ahora},
                    Nuevo = Data#{reserva := Nueva},
                    notificar(Nuevo, reservado),
                    {next_state, reservado, Nuevo,
                     [{reply, From, ok},
                      {state_timeout, ?TIMEOUT_CONFIRMADA_MS, expirada}]}
            end;
        _ ->
            {keep_state, Data, [{reply, From, {error, reserva_no_encontrada}}]}
    end;
handle_event({call, From}, {confirmar, _}, _State, Data) ->
    {keep_state, Data, [{reply, From, {error, reserva_no_encontrada}}]};

handle_event({call, From}, {cancelar, ReservaId}, reservado,
             #{reserva := Reserva} = Data) ->
    case maps:get(id, Reserva, undefined) of
        ReservaId ->
            Nuevo = Data#{reserva := undefined},
            notificar(Nuevo, libre),
            {next_state, libre, Nuevo, [{reply, From, ok}]};
        _ ->
            {keep_state, Data, [{reply, From, {error, reserva_no_encontrada}}]}
    end;
handle_event({call, From}, {cancelar, _}, _State, Data) ->
    {keep_state, Data, [{reply, From, {error, reserva_no_encontrada}}]};

handle_event({call, From}, {liberar, Motivo}, State, Data) ->
    Nuevo = Data#{reserva := undefined, motivo := Motivo},
    notificar(Nuevo, libre),
    {next_state, libre, Nuevo, [{reply, From, {ok, State}}]};

handle_event({call, From}, {ocupar, Placa}, libre, Data) ->
    Ahora = p49_util:ahora_seg(),
    Reserva = #{id => undefined, placa => Placa, edificio => undefined,
                confirmada => true, entrada_en => Ahora},
    Nuevo = Data#{reserva := Reserva},
    notificar(Nuevo, ocupado),
    {next_state, ocupado, Nuevo, [{reply, From, ok}]};
handle_event({call, From}, {ocupar, Placa}, reservado,
             #{reserva := Reserva} = Data) ->
    PlacaReserva = maps:get(placa, Reserva, undefined),
    case Placa =:= undefined orelse Placa =:= PlacaReserva of
        true ->
            Ahora = p49_util:ahora_seg(),
            Nueva = Reserva#{confirmada := true, entrada_en => Ahora},
            Nuevo = Data#{reserva := Nueva},
            notificar(Nuevo, ocupado),
            {next_state, ocupado, Nuevo, [{reply, From, ok}]};
        false ->
            {keep_state, Data, [{reply, From, {error, placa_no_coincide}}]}
    end;
handle_event({call, From}, {ocupar, _}, ocupado, Data) ->
    {keep_state, Data, [{reply, From, {ok, ya_ocupado}}]};
handle_event({call, From}, {ocupar, _}, _State, Data) ->
    {keep_state, Data, [{reply, From, {error, cajon_fuera_de_servicio}}]};

handle_event({call, From}, {fuera_servicio, _Motivo}, ocupado, Data) ->
    {keep_state, Data, [{reply, From, {error, cajon_ocupado}}]};
handle_event({call, From}, {fuera_servicio, Motivo}, State, Data) ->
    Nuevo = Data#{reserva := undefined, motivo := Motivo},
    notificar(Nuevo, fuera_servicio),
    {next_state, fuera_servicio, Nuevo,
     [{reply, From, {ok, State}}]};

handle_event({call, From}, habilitar, fuera_servicio, Data) ->
    Nuevo = Data#{reserva := undefined, motivo := undefined},
    notificar(Nuevo, libre),
    {next_state, libre, Nuevo, [{reply, From, ok}]};
handle_event({call, From}, habilitar, ocupado, Data) ->
    {keep_state, Data, [{reply, From, {error, cajon_ocupado}}]};
handle_event({call, From}, habilitar, _State, Data) ->
    {keep_state, Data, [{reply, From, {error, estado_invalido}}]};

handle_event({call, From}, {restaurar, Info}, _State, Data) ->
    Nuevo = Data#{reserva := maps:get(reserva, Info, undefined),
                  motivo := maps:get(motivo, Info, undefined)},
    Estado = case maps:get(estado, Info, libre) of
                 reservado ->
                     case maps:get(reserva, Nuevo, undefined) of
                         undefined -> libre;
                         Reserva -> estado_reserva_restaurada(Reserva)
                     end;
                 Otro -> Otro
             end,
    notificar(Nuevo, Estado),
    Acciones = [{reply, From, ok} | acciones_restauracion(Estado, Nuevo)],
    {next_state, Estado, Nuevo, Acciones};

handle_event({call, From}, _Msg, _State, Data) ->
    {keep_state, Data, [{reply, From, {error, operacion_invalida}}]};

handle_event(state_timeout, expirada, reservado, Data) ->
    Nuevo = Data#{reserva := undefined, motivo := <<"Reserva expirada">>},
    notificar(Nuevo, libre),
    {next_state, libre, Nuevo};

handle_event(_EventType, _Event, _State, Data) ->
    {keep_state, Data}.

estado_reserva_restaurada(Reserva) ->
    case maps:get(confirmada, Reserva, false) of
        true -> reservado;
        false ->
            Ahora = p49_util:ahora_seg(),
            case maps:get(expira_en, Reserva, undefined) of
                undefined -> reservado;
                Expira when Expira > Ahora -> reservado;
                _ -> libre
            end
    end.

acciones_restauracion(reservado, #{reserva := Reserva}) ->
    case maps:get(confirmada, Reserva, false) of
        true -> [{state_timeout, ?TIMEOUT_CONFIRMADA_MS, expirada}];
        false ->
            Ahora = p49_util:ahora_seg(),
            case maps:get(expira_en, Reserva, undefined) of
                undefined -> [];
                Expira -> [{state_timeout, max(1, Expira - Ahora) * 1000, expirada}]
            end
    end;
acciones_restauracion(_Estado, _Data) ->
    [].

info(State, Data) ->
    #{id => maps:get(id, Data),
      zona => maps:get(zona, Data),
      numero => maps:get(numero, Data),
      tipo => maps:get(tipo, Data),
      estado => State,
      reserva => maps:get(reserva, Data, undefined),
      motivo => maps:get(motivo, Data, undefined)}.

notificar(Data, Estado) ->
    p49_zona:reportar_estado(maps:get(zona, Data),
                             maps:get(numero, Data),
                             Estado,
                             maps:get(reserva, Data, undefined),
                             self()).
