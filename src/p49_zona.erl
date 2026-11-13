-module(p49_zona).
-compile(nowarn_deprecated_catch).
-behaviour(gen_server).

-export([start_link/1, nombre/1, resumen/1, cajones/1, cajones/2,
         cajones_admin/1,
         recomendar/2, recomendar/3, reservar/5, confirmar/3,
         cancelar/4, liberar/3, ocupar/3, salida/3,
         fuera_servicio/3, habilitar/2,
         abrir/1, cerrar/1, estado/1, reportar_estado/5,
         cajon_listo/3, presion/1, detalle/2, reservas_de_placa/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link(ZonaId) ->
    gen_server:start_link({local, nombre(ZonaId)}, ?MODULE, [ZonaId], []).

nombre(ZonaId) ->
    p49_config:zona_atom(ZonaId).

resumen(ZonaId) -> gen_server:call(nombre(ZonaId), resumen).
cajones(ZonaId) -> gen_server:call(nombre(ZonaId), cajones).
cajones(ZonaId, Limite) -> gen_server:call(nombre(ZonaId), {cajones, Limite}).
%% Igual que cajones/1 pero incluye los datos de la estancia (placa, reserva,
%% hora de entrada). Solo se usa en el panel administrativo autenticado.
cajones_admin(ZonaId) -> gen_server:call(nombre(ZonaId), cajones_admin).
recomendar(ZonaId, EdificioId) ->
    gen_server:call(nombre(ZonaId), {recomendar, EdificioId, undefined, []}).
recomendar(ZonaId, EdificioId, Tipo) ->
    gen_server:call(nombre(ZonaId), {recomendar, EdificioId, Tipo, []}).
reservar(ZonaId, CajonId, ReservaId, Placa, Edificio) ->
    gen_server:call(nombre(ZonaId),
                    {reservar, CajonId, ReservaId, Placa, Edificio}, 8000).
confirmar(ZonaId, CajonId, ReservaId) ->
    gen_server:call(nombre(ZonaId), {confirmar, CajonId, ReservaId}, 8000).
cancelar(ZonaId, CajonId, ReservaId, Motivo) ->
    gen_server:call(nombre(ZonaId), {cancelar, CajonId, ReservaId, Motivo}, 8000).
liberar(ZonaId, CajonId, Motivo) ->
    gen_server:call(nombre(ZonaId), {liberar, CajonId, Motivo}, 8000).
ocupar(ZonaId, CajonId, Placa) ->
    gen_server:call(nombre(ZonaId), {ocupar, CajonId, Placa}, 8000).
salida(ZonaId, CajonId, Placa) ->
    gen_server:call(nombre(ZonaId), {salida, CajonId, Placa}, 8000).
fuera_servicio(ZonaId, CajonId, Motivo) ->
    gen_server:call(nombre(ZonaId), {fuera_servicio, CajonId, Motivo}, 8000).
habilitar(ZonaId, CajonId) ->
    gen_server:call(nombre(ZonaId), {habilitar, CajonId}, 8000).
abrir(ZonaId) -> gen_server:call(nombre(ZonaId), abrir, 15000).
cerrar(ZonaId) -> gen_server:call(nombre(ZonaId), cerrar, 15000).
estado(ZonaId) -> gen_server:call(nombre(ZonaId), estado).
presion(ZonaId) -> gen_server:call(nombre(ZonaId), presion).
detalle(ZonaId, CajonId) -> gen_server:call(nombre(ZonaId), {detalle, CajonId}).
reservas_de_placa(ZonaId, Placa) ->
    gen_server:call(nombre(ZonaId), {reservas_de_placa, Placa}).

reportar_estado(ZonaId, Numero, Estado, Reserva, Pid) ->
    case whereis(nombre(ZonaId)) of
        undefined -> ok;
        _ -> gen_server:cast(nombre(ZonaId),
                             {cajon_estado, Numero, Estado, Reserva, Pid})
    end.

cajon_listo(ZonaId, Numero, Pid) ->
    case whereis(nombre(ZonaId)) of
        undefined -> ok;
        _ -> gen_server:cast(nombre(ZonaId), {cajon_listo, Numero, Pid})
    end.

init([ZonaId]) ->
    {ok, ZonaCfg} = p49_config:zona(ZonaId),
    Configs = p49_config:cajones_zona(ZonaId),
    Pids = maps:from_list(p49_cajon_sup:lista(ZonaId)),
    Cajones = maps:from_list(
                [{maps:get(numero, Cfg),
                  cargar_cajon(Cfg, maps:get(maps:get(numero, Cfg), Pids, undefined))}
                 || Cfg <- Configs]),
    [erlang:monitor(process, Pid) || Pid <- maps:values(Pids)],
    erlang:send_after(30000, self(), limpiar_presion),
    Resumen = calcular_resumen(ZonaId, ZonaCfg, true, Cajones, []),
    p49_registro:movimiento(zona_iniciada,
                            #{zona => ZonaId,
                              total => maps:get(total, Resumen),
                              libres => maps:get(libres, Resumen)}),
    logger:info("zona ~s iniciada con ~p cajones",
                [ZonaId, map_size(Cajones)],
                #{modulo => ?MODULE, zona => ZonaId}),
    {ok, #{id => ZonaId,
           nombre => maps:get(nombre, ZonaCfg),
           abierto => true,
           cajones => Cajones,
           asignaciones => [],
           inicio => p49_util:ahora_seg()}}.

cargar_cajon(Cfg, undefined) ->
    #{pid => undefined, estado => fuera_servicio,
      numero => maps:get(numero, Cfg), tipo => maps:get(tipo, Cfg),
      reserva => undefined, motivo => <<"Sin lectura del sensor">>};
cargar_cajon(Cfg, Pid) ->
    case catch p49_cajon:estado(Pid) of
        #{estado := Estado, reserva := Reserva, motivo := Motivo} ->
            #{pid => Pid, estado => Estado, numero => maps:get(numero, Cfg),
              tipo => maps:get(tipo, Cfg), reserva => Reserva,
              motivo => Motivo};
        _ ->
            #{pid => undefined, estado => fuera_servicio,
              numero => maps:get(numero, Cfg), tipo => maps:get(tipo, Cfg),
              reserva => undefined, motivo => <<"Sensor sin respuesta">>}
    end.

handle_call(resumen, _From, State) ->
    {reply, resumen_state(State), State};
handle_call(cajones, _From, State) ->
    {reply, lista_cajones(State, infinity, publico), State};
handle_call({cajones, Limite}, _From, State) ->
    {reply, lista_cajones(State, Limite, publico), State};
handle_call(cajones_admin, _From, State) ->
    {reply, lista_cajones(State, infinity, admin), State};
handle_call({recomendar, EdificioId, Tipo, Excluir}, _From, State) ->
    {reply, recomendar_state(State, EdificioId, Tipo, Excluir), State};
handle_call(estado, _From, State) ->
    {reply, #{resumen => resumen_state(State),
              cajones => lista_cajones(State, infinity, publico)}, State};
handle_call(presion, _From, State) ->
    {reply, presion_state(State), State};
handle_call({detalle, CajonId}, _From, State) ->
    Numero = p49_config:numero_de_cajon(CajonId),
    case maps:find(Numero, maps:get(cajones, State)) of
        {ok, Entrada} -> {reply, {ok, Entrada}, State};
        error -> {reply, {error, cajon_no_encontrado}, State}
    end;
handle_call({reservas_de_placa, Placa}, _From, State) ->
    {reply, reservas_de_placa_state(State, Placa), State};

handle_call({reservar, CajonId, ReservaId, Placa, Edificio}, _From, State) ->
    case maps:get(abierto, State) of
        false ->
            {reply, {error, zona_cerrada}, State};
        true ->
            Numero = p49_config:numero_de_cajon(CajonId),
            case maps:find(Numero, maps:get(cajones, State)) of
                {ok, Entrada} ->
                    case pid_vivo(Entrada, maps:get(id, State), Numero) of
                        undefined ->
                            {reply, {error, cajon_no_disponible}, State};
                        Pid ->
                            TTL = p49_config:reserva_ttl(),
                            Resultado = intentar(fun() ->
                                p49_cajon:reservar(Pid, ReservaId, Placa,
                                                   Edificio, TTL)
                            end),
                            reservar_resultado(Resultado, Numero, Entrada,
                                               Pid, ReservaId, Placa,
                                               Edificio, State)
                    end;
                error ->
                    {reply, {error, cajon_no_encontrado}, State}
            end
    end;

handle_call({confirmar, CajonId, ReservaId}, _From, State) ->
    con_cajon(State, CajonId, fun(Numero, Entrada, Pid) ->
        case intentar(fun() -> p49_cajon:confirmar(Pid, ReservaId) end) of
            ok ->
                Nueva = actualizar_entrada(State, Numero,
                                           Entrada#{estado := reservado}),
                p49_registro:contador(confirmadas, 1),
                p49_registro:movimiento(reserva_confirmada,
                                        #{zona => maps:get(id, State),
                                          cajon => CajonId,
                                          reserva_id => ReservaId}),
                {reply, ok, Nueva};
            {error, Motivo} ->
                {reply, {error, Motivo}, refrescar(State, Numero, Entrada)}
        end
    end);

handle_call({cancelar, CajonId, ReservaId, Motivo}, _From, State) ->
    con_cajon(State, CajonId, fun(Numero, Entrada, Pid) ->
        case intentar(fun() -> p49_cajon:cancelar(Pid, ReservaId) end) of
            ok ->
                Nueva = actualizar_entrada(State, Numero,
                                           Entrada#{estado := libre,
                                                    reserva := undefined}),
                p49_registro:contador(canceladas, 1),
                p49_registro:movimiento(reserva_cancelada,
                                        #{zona => maps:get(id, State),
                                          cajon => CajonId,
                                          reserva_id => ReservaId,
                                          motivo => Motivo}),
                {reply, ok, Nueva};
            {error, Error} ->
                {reply, {error, Error}, refrescar(State, Numero, Entrada)}
        end
    end);

handle_call({liberar, CajonId, Motivo}, _From, State) ->
    con_cajon(State, CajonId, fun(Numero, Entrada, Pid) ->
        case intentar(fun() -> p49_cajon:liberar(Pid, Motivo) end) of
            {ok, _Anterior} ->
                Nueva = actualizar_entrada(State, Numero,
                                           Entrada#{estado := libre,
                                                    reserva := undefined,
                                                    motivo := undefined}),
                p49_registro:movimiento(cajon_liberado,
                                        #{zona => maps:get(id, State),
                                          cajon => CajonId, motivo => Motivo}),
                {reply, ok, Nueva};
            {error, Error} ->
                {reply, {error, Error}, refrescar(State, Numero, Entrada)}
        end
    end);

handle_call({ocupar, CajonId, Placa}, _From, State) ->
    con_cajon(State, CajonId, fun(Numero, Entrada, Pid) ->
        case intentar(fun() -> p49_cajon:ocupar(Pid, Placa) end) of
            ok ->
                Nueva = refrescar(State, Numero, Entrada, Pid),
                Actual = maps:get(Numero, maps:get(cajones, Nueva)),
                Info = datos_estancia(maps:get(id, State),
                                      maps:get(nombre, State), Actual),
                p49_registro:contador(entradas, 1),
                p49_registro:movimiento(
                  entrada_registrada,
                  #{zona => maps:get(id, State),
                    cajon => CajonId,
                    placa => Placa,
                    entrada_en => maps:get(entrada_en, Info, undefined)}),
                {reply, {ok, Info}, Nueva};
            {ok, ya_ocupado} ->
                Nueva = refrescar(State, Numero, Entrada, Pid),
                Actual = maps:get(Numero, maps:get(cajones, Nueva)),
                Info = datos_estancia(maps:get(id, State),
                                      maps:get(nombre, State), Actual),
                {reply, {ok, Info#{ya_registrada => true}}, Nueva};
            {error, Motivo} ->
                {reply, {error, Motivo}, refrescar(State, Numero, Entrada, Pid)}
        end
    end);

handle_call({salida, CajonId, Placa}, _From, State) ->
    con_cajon(State, CajonId, fun(Numero, Entrada, Pid) ->
        Info = datos_estancia(maps:get(id, State), maps:get(nombre, State),
                              Entrada),
        case intentar(fun() ->
                              p49_cajon:liberar(Pid, <<"Salida del usuario">>)
                      end) of
            {ok, _Anterior} ->
                Nueva = actualizar_entrada(State, Numero,
                                           Entrada#{estado := libre,
                                                    reserva := undefined,
                                                    motivo := undefined}),
                SalidaEn = p49_util:ahora_seg(),
                Duracion = duracion(maps:get(entrada_en, Info, undefined),
                                    SalidaEn),
                p49_registro:contador(salidas, 1),
                p49_registro:movimiento(
                  salida_registrada,
                  #{zona => maps:get(id, State),
                    cajon => CajonId,
                    placa => Placa,
                    duracion_seg => Duracion}),
                {reply, {ok, Info#{estado := libre,
                                   salida_en => SalidaEn,
                                   duracion_seg => Duracion}}, Nueva};
            {error, Motivo} ->
                {reply, {error, Motivo}, refrescar(State, Numero, Entrada, Pid)}
        end
    end);

handle_call({fuera_servicio, CajonId, Motivo}, _From, State) ->
    con_cajon(State, CajonId, fun(Numero, Entrada, Pid) ->
        case intentar(fun() -> p49_cajon:fuera_servicio(Pid, Motivo) end) of
            {ok, _Anterior} ->
                Nueva = actualizar_entrada(State, Numero,
                                           Entrada#{estado := fuera_servicio,
                                                    reserva := undefined,
                                                    motivo := Motivo}),
                p49_registro:contador(fuera_servicio_manual, 1),
                p49_registro:movimiento(cajon_fuera_servicio,
                                        #{zona => maps:get(id, State),
                                          cajon => CajonId, motivo => Motivo}),
                {reply, ok, Nueva};
            {error, Error} ->
                {reply, {error, Error}, refrescar(State, Numero, Entrada)}
        end
    end);

handle_call({habilitar, CajonId}, _From, State) ->
    con_cajon(State, CajonId, fun(Numero, Entrada, Pid) ->
        case intentar(fun() -> p49_cajon:habilitar(Pid) end) of
            ok ->
                Nueva = actualizar_entrada(State, Numero,
                                           Entrada#{estado := libre,
                                                    reserva := undefined,
                                                    motivo := undefined}),
                p49_registro:movimiento(cajon_habilitado,
                                        #{zona => maps:get(id, State),
                                          cajon => CajonId}),
                {reply, ok, Nueva};
            {error, Error} ->
                {reply, {error, Error}, refrescar(State, Numero, Entrada)}
        end
    end);

handle_call(abrir, _From, State) ->
    p49_registro:contador(aperturas_zona, 1),
    p49_registro:movimiento(zona_abierta, #{zona => maps:get(id, State)}),
    {reply, ok, State#{abierto := true}};

handle_call(cerrar, _From, State) ->
    Cajones = maps:get(cajones, State),
    Nuevos = maps:map(
               fun(_Numero, Entrada) ->
                   case maps:get(estado, Entrada) of
                       reservado ->
                           Pid = maps:get(pid, Entrada),
                           case is_pid(Pid) of
                               true ->
                                   catch p49_cajon:liberar(
                                           Pid, <<"Cierre de estacionamiento">>);
                               false -> ok
                           end,
                           Entrada#{estado := libre, reserva := undefined};
                       _ -> Entrada
                   end
               end, Cajones),
    p49_registro:contador(cierres_zona, 1),
    p49_registro:movimiento(zona_cerrada, #{zona => maps:get(id, State)}),
    {reply, ok, State#{abierto := false, cajones := Nuevos}};

handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({cajon_estado, Numero, Estado, Reserva, Pid}, State) ->
    Cajones = maps:get(cajones, State),
    case maps:find(Numero, Cajones) of
        {ok, Entrada} ->
            PidActual = maps:get(pid, Entrada),
            case PidActual =:= undefined orelse PidActual =:= Pid of
                true ->
                    Anterior = maps:get(estado, Entrada),
                    Nueva = Entrada#{pid := Pid, estado := Estado,
                                     reserva := Reserva},
                    case Anterior =:= reservado andalso Estado =:= libre of
                        true ->
                            p49_registro:movimiento(
                              reserva_expirada,
                              #{zona => maps:get(id, State),
                                cajon => p49_config:cajon_id(
                                           maps:get(id, State), Numero)});
                        false -> ok
                    end,
                    {noreply, State#{cajones := maps:put(Numero, Nueva, Cajones)}};
                false ->
                    {noreply, State}
            end;
        error ->
            {noreply, State}
    end;

handle_cast({cajon_listo, Numero, Pid}, State) ->
    Cajones = maps:get(cajones, State),
    case maps:find(Numero, Cajones) of
        {ok, Entrada} ->
            erlang:monitor(process, Pid),
            Conocido = #{estado => maps:get(estado, Entrada),
                         reserva => maps:get(reserva, Entrada),
                         motivo => maps:get(motivo, Entrada)},
            catch p49_cajon:restaurar(Pid, Conocido),
            Nueva = Entrada#{pid := Pid},
            {noreply, State#{cajones := maps:put(Numero, Nueva, Cajones)}};
        error ->
            case catch p49_cajon:estado(Pid) of
                #{estado := Estado, tipo := Tipo, reserva := Reserva,
                  motivo := Motivo} ->
                    Entrada = #{pid => Pid, estado => Estado,
                                numero => Numero, tipo => Tipo,
                                reserva => Reserva, motivo => Motivo},
                    {noreply, State#{cajones := maps:put(Numero, Entrada, Cajones)}};
                _ ->
                    {noreply, State}
            end
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, Razon}, State) ->
    Cajones = maps:get(cajones, State),
    case [{N, E} || {N, E} <- maps:to_list(Cajones), maps:get(pid, E) =:= Pid] of
        [{Numero, Entrada} | _] ->
            p49_registro:incidencia(cajon_reiniciado,
                                    #{zona => maps:get(id, State),
                                      cajon => p49_config:cajon_id(
                                                 maps:get(id, State), Numero),
                                      razon => p49_util:bin(Razon)}),
            Nueva = Entrada#{pid := undefined},
            {noreply, State#{cajones := maps:put(Numero, Nueva, Cajones)}};
        [] ->
            {noreply, State}
    end;

handle_info(limpiar_presion, State) ->
    Limite = p49_util:ahora_ms() - 60000,
    Asignaciones = [T || T <- maps:get(asignaciones, State), T >= Limite],
    erlang:send_after(30000, self(), limpiar_presion),
    {noreply, State#{asignaciones := Asignaciones}};

handle_info(_Info, State) ->
    {noreply, State}.

reservar_resultado({ok, Reserva}, Numero, Entrada, Pid, ReservaId,
                   Placa, Edificio, State) ->
    Nueva = actualizar_entrada(State, Numero,
                               Entrada#{pid := Pid, estado := reservado,
                                        reserva := Reserva}),
    Asignaciones = [p49_util:ahora_ms() |
                    lists:sublist(maps:get(asignaciones, Nueva), 300)],
    p49_registro:contador(reservas, 1),
    p49_registro:movimiento(reserva_creada,
                            #{zona => maps:get(id, State),
                              cajon => p49_config:cajon_id(
                                         maps:get(id, State), Numero),
                              reserva_id => ReservaId,
                              placa => Placa,
                              edificio => Edificio}),
    CajonId = p49_config:cajon_id(maps:get(id, State), Numero),
    Info = #{zona => maps:get(id, State),
             zona_nombre => maps:get(nombre, State),
             cajon_id => CajonId,
             numero => Numero,
             tipo => maps:get(tipo, Entrada),
             reserva_id => ReservaId,
             placa => Placa,
             edificio => Edificio,
             expira_en => maps:get(expira_en, Reserva),
             generado_en => p49_util:ahora_seg()},
    {reply, {ok, Info}, Nueva#{asignaciones := Asignaciones}};
reservar_resultado({error, Motivo}, Numero, Entrada, Pid, _ReservaId,
                   _Placa, _Edificio, State) ->
    {reply, {error, Motivo}, refrescar(State, Numero, Entrada, Pid)};
reservar_resultado(_Otro, Numero, Entrada, Pid, _ReservaId,
                   _Placa, _Edificio, State) ->
    {reply, {error, no_disponible}, refrescar(State, Numero, Entrada, Pid)}.

con_cajon(State, CajonId, Fun) ->
    Numero = p49_config:numero_de_cajon(CajonId),
    case maps:find(Numero, maps:get(cajones, State)) of
        {ok, Entrada} ->
            case pid_vivo(Entrada, maps:get(id, State), Numero) of
                undefined -> {reply, {error, cajon_no_disponible}, State};
                Pid -> Fun(Numero, Entrada, Pid)
            end;
        error ->
            {reply, {error, cajon_no_encontrado}, State}
    end.

refrescar(State, Numero, Entrada) ->
    refrescar(State, Numero, Entrada, maps:get(pid, Entrada)).
refrescar(State, Numero, Entrada, Pid) when is_pid(Pid) ->
    case catch p49_cajon:estado(Pid) of
        #{estado := Estado, reserva := Reserva, motivo := Motivo} ->
            Nueva = Entrada#{estado := Estado, reserva := Reserva,
                             motivo := Motivo},
            actualizar_entrada(State, Numero, Nueva);
        _ -> actualizar_entrada(State, Numero, Entrada#{pid := undefined})
    end;
refrescar(State, Numero, Entrada, _Pid) ->
    actualizar_entrada(State, Numero, Entrada).

actualizar_entrada(State, Numero, Entrada) ->
    State#{cajones := maps:put(Numero, Entrada, maps:get(cajones, State))}.

pid_vivo(Entrada, ZonaId, Numero) ->
    case maps:get(pid, Entrada) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> Pid;
                false -> buscar_pid(ZonaId, Numero)
            end;
        _ -> buscar_pid(ZonaId, Numero)
    end.

buscar_pid(ZonaId, Numero) ->
    case catch p49_cajon_sup:pid(ZonaId, Numero) of
        {ok, Pid} -> Pid;
        _ -> undefined
    end.

intentar(Fun) ->
    try Fun()
    catch
        _:_ -> {error, cajon_no_disponible}
    end.

lista_cajones(State, Limite, Modo) ->
    ZonaId = maps:get(id, State),
    Cajones = maps:get(cajones, State),
    Numeros = lists:sort(maps:keys(Cajones)),
    Limitados = case Limite of
                    infinity -> Numeros;
                    N -> lists:sublist(Numeros, N)
                end,
    [cajon_json(ZonaId, maps:get(Numero, Cajones), Modo) || Numero <- Limitados].

cajon_json(ZonaId, Entrada, publico) ->
    #{id => p49_config:cajon_id(ZonaId, maps:get(numero, Entrada, 0)),
      numero => maps:get(numero, Entrada, 0),
      tipo => maps:get(tipo, Entrada),
      estado => maps:get(estado, Entrada),
      motivo => maps:get(motivo, Entrada, undefined)};
cajon_json(ZonaId, Entrada, admin) ->
    Base = cajon_json(ZonaId, Entrada, publico),
    case maps:get(reserva, Entrada, undefined) of
        Reserva when is_map(Reserva) ->
            Base#{placa => maps:get(placa, Reserva, undefined),
                  reserva_id => maps:get(id, Reserva, undefined),
                  confirmada => maps:get(confirmada, Reserva, false),
                  entrada_en => maps:get(entrada_en, Reserva, undefined),
                  expira_en => maps:get(expira_en, Reserva, undefined),
                  edificio => maps:get(edificio, Reserva, undefined)};
        _ ->
            Base#{placa => undefined, reserva_id => undefined}
    end.

%% Datos de la estancia de un cajon (reserva + entrada) listos para que el
%% coordinador los convierta en la respuesta HTTP de entrada/salida.
datos_estancia(ZonaId, ZonaNombre, Entrada) ->
    Reserva = maps:get(reserva, Entrada, undefined),
    {ReservaId, Placa, Confirmada, EntradaEn, ExpiraEn} =
        case Reserva of
            M when is_map(M) ->
                {maps:get(id, M, undefined),
                 maps:get(placa, M, undefined),
                 maps:get(confirmada, M, false),
                 maps:get(entrada_en, M, undefined),
                 maps:get(expira_en, M, undefined)};
            _ ->
                {undefined, undefined, false, undefined, undefined}
        end,
    Numero = maps:get(numero, Entrada),
    #{zona => ZonaId,
      zona_nombre => ZonaNombre,
      cajon_id => p49_config:cajon_id(ZonaId, Numero),
      numero => Numero,
      tipo => maps:get(tipo, Entrada),
      estado => maps:get(estado, Entrada),
      reserva_id => ReservaId,
      placa => Placa,
      confirmada => Confirmada,
      entrada_en => EntradaEn,
      expira_en => ExpiraEn}.

duracion(undefined, _Ahora) -> 0;
duracion(EntradaEn, Ahora) when is_integer(EntradaEn) ->
    max(0, Ahora - EntradaEn).

recomendar_state(State, EdificioId, Tipo, Excluir) ->
    case maps:get(abierto, State) of
        false -> [];
        true ->
            Cajones = maps:get(cajones, State),
            Compatibles = p49_config:tipos_compatibles(Tipo),
            Total = map_size(Cajones),
            Libres = contar(libre, Cajones, libre),
            Distancia = p49_config:distancia(EdificioId, maps:get(id, State)),
            Presion = presion_state(State),
            Ocupacion = case Total of
                            0 -> 1.0;
                            _ -> (Total - Libres) / Total
                        end,
            Candidatos = [{Numero, E} ||
                             {Numero, E} <- maps:to_list(Cajones),
                             maps:get(estado, E) =:= libre,
                             lists:member(maps:get(tipo, E), Compatibles),
                             not lists:member(p49_config:cajon_id(
                                                maps:get(id, State), Numero),
                                              Excluir)],
            %% El desempate depende del edificio y la zona para que dos
            %% estacionamientos vacios no recomienden siempre el mismo numero.
            Semilla = {EdificioId, maps:get(id, State)},
            Ordenados = lists:sort(
                          fun({NumA, A}, {NumB, B}) ->
                              costo_cajon(NumA, A, Tipo, Distancia, Presion,
                                          Ocupacion, Semilla) =<
                                  costo_cajon(NumB, B, Tipo, Distancia,
                                              Presion, Ocupacion, Semilla)
                          end, Candidatos),
            [opcion_cajon(Numero, E, Tipo, Distancia, Presion, Ocupacion,
                          State, Semilla)
             || {Numero, E} <- lists:sublist(Ordenados, 3)]
    end.

costo_cajon(Numero, Entrada, Tipo, Distancia, Presion, Ocupacion, Semilla) ->
    Bonus = case maps:get(tipo, Entrada) =:= Tipo of
                true -> 0.0;
                false -> 8.0
            end,
    %% El jitter solo ordena cajones dentro de la misma zona: distancia,
    %% presion y ocupacion ya decidieron que zona conviene. Al depender de
    %% edificio y zona, el campus vacio no recomienda el mismo numero en
    %% todos los estacionamientos.
    Distancia * 10.0 + Presion * 1.5 + Ocupacion * 25.0 +
        Bonus + erlang:phash2({Semilla, Numero}, 3600) / 1000.0.

opcion_cajon(Numero, Entrada, Tipo, Distancia, Presion, Ocupacion, State,
             Semilla) ->
    ZonaId = maps:get(id, State),
    #{zona => ZonaId,
      zona_nombre => maps:get(nombre, State),
      cajon_id => p49_config:cajon_id(ZonaId, Numero),
      numero => Numero,
      tipo => maps:get(tipo, Entrada),
      tipo_exacto => maps:get(tipo, Entrada) =:= Tipo,
      distancia => Distancia,
      score => p49_util:redondear(
                 costo_cajon(Numero, Entrada, Tipo, Distancia, Presion,
                             Ocupacion, Semilla))}.

resumen_state(State) ->
    calcular_resumen(maps:get(id, State),
                     #{nombre => maps:get(nombre, State)},
                     maps:get(abierto, State),
                     maps:get(cajones, State),
                     maps:get(asignaciones, State)).

calcular_resumen(ZonaId, ZonaCfg, Abierto, Cajones, Asignaciones) ->
    Total = map_size(Cajones),
    Libres = contar(libre, Cajones, libre),
    Reservados = contar(reservado, Cajones, reservado),
    Ocupados = contar(ocupado, Cajones, ocupado),
    Fuera = contar(fuera_servicio, Cajones, fuera_servicio),
    Porcentaje = case Total of
                     0 -> 0.0;
                     _ -> p49_util:redondear(
                            (Ocupados + Reservados) * 100.0 / Total)
                 end,
    Ahora = p49_util:ahora_ms(),
    Presion = length([T || T <- Asignaciones, T >= Ahora - 60000]),
    #{zona => ZonaId,
      nombre => maps:get(nombre, ZonaCfg),
      abierto => Abierto,
      total => Total,
      libres => Libres,
      reservados => Reservados,
      ocupados => Ocupados,
      fuera_servicio => Fuera,
      porcentaje_ocupacion => Porcentaje,
      presion => Presion,
      actualizado_en => p49_util:ahora_seg()}.

contar(Estado, Cajones, _EstadoAtom) ->
    length([1 || E <- maps:values(Cajones), maps:get(estado, E) =:= Estado]).

presion_state(State) ->
    Limite = p49_util:ahora_ms() - 60000,
    length([T || T <- maps:get(asignaciones, State), T >= Limite]).

reservas_de_placa_state(State, Placa) ->
    ZonaId = maps:get(id, State),
    lists:filtermap(
      fun({Numero, Entrada}) ->
              case maps:get(reserva, Entrada, undefined) of
                  #{placa := Otra} = Reserva when Otra =:= Placa ->
                      Estado = maps:get(estado, Entrada),
                      {true, #{zona => ZonaId,
                               zona_nombre => maps:get(nombre, State),
                               cajon_id => p49_config:cajon_id(ZonaId,
                                                               Numero),
                               numero => Numero,
                               tipo => maps:get(tipo, Entrada),
                               reserva_id => maps:get(id, Reserva, undefined),
                               estado => Estado,
                               confirmada =>
                                   Estado =:= ocupado orelse
                                       maps:get(confirmada, Reserva, false),
                               entrada_en =>
                                   maps:get(entrada_en, Reserva, undefined),
                               expira_en =>
                                   maps:get(expira_en, Reserva, undefined)}};
                  _ ->
                      false
              end
      end, maps:to_list(maps:get(cajones, State))).
