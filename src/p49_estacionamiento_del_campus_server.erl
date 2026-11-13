-module(p49_estacionamiento_del_campus_server).
-compile(nowarn_deprecated_catch).
-behaviour(gen_server).

-export([start_link/0, ping/0, state/0,
         catalogo/0, mapa/1, recomendar/3, alternativa/3, alternativa/4,
         confirmar/2, cancelar/2,
         entrada/2, salida/2, estado_placa/1,
         admin_estado/0, admin_cajones/1, admin_zona_estado/2,
         admin_cajon_estado/3, admin_cajon_liberar/2, movimientos/1, incidencias/1,
         registrar_incidencia/2, simular/1, escenario/0,
         diagnostico/0, metricas/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TIMEOUT_SIM, 120000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

ping() -> gen_server:call(?MODULE, ping).
state() -> gen_server:call(?MODULE, state).
catalogo() -> gen_server:call(?MODULE, catalogo).
mapa(Edificio) -> gen_server:call(?MODULE, {mapa, Edificio}).
recomendar(Edificio, Tipo, Placa) ->
    gen_server:call(?MODULE, {recomendar, Edificio, Tipo, Placa}, 20000).
alternativa(ReservaId, CajonId, Tipo) ->
    gen_server:call(?MODULE, {alternativa, ReservaId, CajonId, Tipo}, 20000).
%% Igual que alternativa/3, pero intenta primero el cajon que el usuario
%% eligio. El coordinador valida que ese cajon este entre las opciones
%% recomendadas; si ya se ocupo, cae en la siguiente mejor opcion.
alternativa(ReservaId, CajonId, Tipo, ObjetivoId) ->
    gen_server:call(?MODULE,
                    {alternativa, ReservaId, CajonId, Tipo, ObjetivoId},
                    20000).
confirmar(ReservaId, CajonId) ->
    gen_server:call(?MODULE, {confirmar, ReservaId, CajonId}, 15000).
cancelar(ReservaId, CajonId) ->
    gen_server:call(?MODULE, {cancelar, ReservaId, CajonId}, 15000).
entrada(Placa, CajonId) ->
    gen_server:call(?MODULE, {entrada, Placa, CajonId}, 15000).
salida(Placa, CajonId) ->
    gen_server:call(?MODULE, {salida, Placa, CajonId}, 15000).
estado_placa(Placa) ->
    gen_server:call(?MODULE, {estado_placa, Placa}, 15000).
admin_estado() -> gen_server:call(?MODULE, admin_estado, 15000).
admin_cajones(Zona) -> gen_server:call(?MODULE, {admin_cajones, Zona}, 15000).
admin_zona_estado(Zona, Estado) ->
    gen_server:call(?MODULE, {admin_zona_estado, Zona, Estado}, 20000).
admin_cajon_estado(CajonId, Estado, Motivo) ->
    gen_server:call(?MODULE, {admin_cajon_estado, CajonId, Estado, Motivo}, 15000).
%% Libera un cajon en cualquier estado (ocupado, reservado o fuera de
%% servicio). Es una accion administrativa explicita y queda registrada.
admin_cajon_liberar(CajonId, Motivo) ->
    gen_server:call(?MODULE, {admin_cajon_liberar, CajonId, Motivo}, 15000).
movimientos(Limite) -> p49_registro:movimientos(Limite).
incidencias(Limite) -> p49_registro:incidencias(Limite).
registrar_incidencia(Tipo, Datos) -> p49_registro:incidencia(Tipo, Datos).
simular(Params) -> gen_server:call(?MODULE, {simular, Params}, ?TIMEOUT_SIM).
escenario() -> gen_server:call(?MODULE, escenario, ?TIMEOUT_SIM).
diagnostico() -> gen_server:call(?MODULE, diagnostico, 15000).
metricas() -> gen_server:call(?MODULE, metricas, 15000).

init([]) ->
    logger:info("coordinador de estacionamiento iniciado",
                #{modulo => ?MODULE}),
    {ok, #{inicio => p49_util:ahora_seg(), ultima_simulacion => undefined}}.

handle_call(ping, _From, State) ->
    {reply, pong, State};
handle_call(state, _From, State) ->
    {reply, #{iniciado_en => maps:get(inicio, State),
              zonas => resumenes_zonas(),
              ultima_simulacion => maps:get(ultima_simulacion, State)}, State};
handle_call(catalogo, _From, State) ->
    Zonas = resumenes_zonas(),
    {reply, #{edificios => p49_config:edificios(),
              zonas => Zonas,
              tipos_usuario => p49_config:tipos_usuario(),
              total_cajones => p49_config:total_cajones(),
              resumen => totales(Zonas),
              actualizado_en => p49_util:ahora_seg()}, State};
handle_call({mapa, EdificioId}, _From, State) ->
    {reply, mapa_respuesta(EdificioId), State};
handle_call({recomendar, EdificioId, Tipo, Placa}, _From, State) ->
    {Respuesta, Nuevo} = recomendar_respuesta(EdificioId, Tipo, Placa, State),
    {reply, Respuesta, Nuevo};
handle_call({alternativa, ReservaId, CajonId, Tipo}, _From, State) ->
    {Respuesta, Nuevo} = alternativa_respuesta(ReservaId, CajonId, Tipo,
                                               undefined, State),
    {reply, Respuesta, Nuevo};
handle_call({alternativa, ReservaId, CajonId, Tipo, ObjetivoId}, _From, State) ->
    {Respuesta, Nuevo} = alternativa_respuesta(ReservaId, CajonId, Tipo,
                                               ObjetivoId, State),
    {reply, Respuesta, Nuevo};
handle_call({confirmar, ReservaId, CajonId}, _From, State) ->
    {reply, confirmar_respuesta(ReservaId, CajonId), State};
handle_call({cancelar, ReservaId, CajonId}, _From, State) ->
    {reply, cancelar_respuesta(ReservaId, CajonId), State};
handle_call({entrada, Placa, CajonId}, _From, State) ->
    {reply, entrada_respuesta(Placa, CajonId), State};
handle_call({salida, Placa, CajonId}, _From, State) ->
    {reply, salida_respuesta(Placa, CajonId), State};
handle_call({estado_placa, Placa}, _From, State) ->
    {reply, estado_placa_respuesta(Placa), State};
handle_call(admin_estado, _From, State) ->
    Zonas = resumenes_zonas(),
    {reply, #{resumen => totales(Zonas),
              zonas => Zonas,
              contadores => p49_registro:contadores(),
              registro => p49_registro:estado(),
              movimientos => p49_registro:movimientos(25),
              incidencias => p49_registro:incidencias(15),
              ultima_simulacion => maps:get(ultima_simulacion, State),
              actualizado_en => p49_util:ahora_seg()}, State};
handle_call({admin_cajones, ZonaId}, _From, State) ->
    {reply, admin_cajones_respuesta(ZonaId), State};
handle_call({admin_zona_estado, ZonaId, Estado}, _From, State) ->
    {reply, admin_zona_estado_respuesta(ZonaId, Estado), State};
handle_call({admin_cajon_estado, CajonId, Estado, Motivo}, _From, State) ->
    {reply, admin_cajon_estado_respuesta(CajonId, Estado, Motivo), State};
handle_call({admin_cajon_liberar, CajonId, Motivo}, _From, State) ->
    {reply, admin_cajon_liberar_respuesta(CajonId, Motivo), State};
handle_call({simular, Params}, _From, State) ->
    case p49_simulacion:concurrente(Params) of
        {ok, Resultado} ->
            {reply, {ok, Resultado}, State#{ultima_simulacion := Resultado}};
        {error, Motivo} ->
            {reply, {error, Motivo}, State}
    end;
handle_call(escenario, _From, State) ->
    case p49_simulacion:escenario() of
        {ok, Resultado} ->
            {reply, {ok, Resultado}, State#{ultima_simulacion := Resultado}};
        {error, Motivo} ->
            {reply, {error, Motivo}, State}
    end;
handle_call(diagnostico, _From, State) ->
    {reply, diagnostico_respuesta(State), State};
handle_call(metricas, _From, State) ->
    Zonas = resumenes_zonas(),
    {reply, #{resumen => totales(Zonas), zonas => Zonas,
              contadores => p49_registro:contadores(),
              memoria_total => erlang:memory(total),
              actualizado_en => p49_util:ahora_seg()}, State};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.

%% ------------------------------------------------------------------
%% Flujo del alumno
%% ------------------------------------------------------------------

mapa_respuesta(EdificioId) ->
    case p49_config:edificio(EdificioId) of
        {ok, Edificio} ->
            Recomendadas = maps:get(zonas, Edificio),
            %% Se envian los cuatro estacionamientos para que el estudiante
            %% pueda consultar todo el campus. Las recomendadas van marcadas
            %% en `recomendadas` y la interfaz las resalta.
            Zonas = [mapa_zona(ZonaId) || ZonaId <- ids_zonas()],
            {ok, #{edificio => EdificioId,
                   edificio_nombre => maps:get(nombre, Edificio),
                   recomendadas => Recomendadas,
                   zonas => Zonas,
                   zonas_campus => resumenes_zonas(),
                   actualizado_en => p49_util:ahora_seg()}};
        {error, Motivo} ->
            {error, Motivo}
    end.

mapa_zona(ZonaId) ->
    Resumen = safe_resumen(ZonaId),
    #{id => ZonaId,
      nombre => maps:get(nombre, Resumen),
      abierto => maps:get(abierto, Resumen),
      resumen => Resumen,
      cajones => safe_cajones(ZonaId)}.

recomendar_respuesta(EdificioId, Tipo, Placa, State) ->
    p49_registro:contador(solicitudes, 1),
    case validar_solicitud(EdificioId, Tipo, Placa) of
        {ok, Edificio} ->
            PlacaLimpia = p49_util:limpiar_placa(Placa),
            case liberar_reservas_temporales(PlacaLimpia) of
                ok ->
                    Opciones = opciones(EdificioId, Tipo, []),
                    case sostener(Opciones, PlacaLimpia, EdificioId, []) of
                        {ok, Info, Restantes} ->
                            Respuesta = respuesta_recomendacion(
                                          Info, Restantes, Edificio, Tipo),
                            {{ok, Respuesta}, State};
                        {error, Motivo} ->
                            p49_registro:contador(rechazos, 1),
                            {{error, Motivo}, State}
                    end;
                {error, Motivo} ->
                    p49_registro:contador(rechazos, 1),
                    {{error, Motivo}, State}
            end;
        {error, Motivo} ->
            {{error, Motivo}, State}
    end.

alternativa_respuesta(ReservaId, CajonId, TipoSugerido, ObjetivoId, State) ->
    case detalle_reserva(CajonId) of
        {ok, #{estado := reservado, reserva := Reserva, tipo := TipoCajon}}
          when is_map(Reserva) ->
            case maps:get(id, Reserva, undefined) =:= ReservaId of
                false ->
                    {{error, reserva_no_encontrada}, State};
                true ->
                    case maps:get(confirmada, Reserva, false) of
                        true ->
                            {{error, reserva_ya_confirmada}, State};
                        false ->
                            Edificio = maps:get(edificio, Reserva),
                            Placa = maps:get(placa, Reserva),
                            Tipo = tipo_para_alternativa(TipoSugerido, TipoCajon),
                            Opciones = opciones(Edificio, Tipo, [CajonId]),
                            Preferidas = preferir_objetivo(ObjetivoId, Opciones),
                            case sostener(Preferidas, Placa, Edificio, []) of
                                {ok, Info, _Restantes} ->
                                    ZonaVieja = p49_config:zona_de_cajon(CajonId),
                                    p49_zona:cancelar(ZonaVieja, CajonId,
                                                      ReservaId,
                                                      <<"Cambio de recomendacion">>),
                                    %% Se recalculan las opciones despues de
                                    %% liberar el cajon anterior y se coloca
                                    %% primero en su zona. Asi la otra tarjeta
                                    %% conserva el cajon que el alumno ya veia
                                    %% en lugar de saltar a otro numero.
                                    Restantes = preferir_objetivo(
                                                  CajonId,
                                                  opciones(Edificio, Tipo, [])),
                                    {ok, EdificioCfg} = p49_config:edificio(Edificio),
                                    Respuesta = respuesta_recomendacion(
                                                  Info, Restantes, EdificioCfg, Tipo),
                                    {{ok, Respuesta}, State};
                                {error, Motivo} ->
                                    {{error, Motivo}, State}
                            end
                    end
            end;
        {ok, _Otra} ->
            {{error, reserva_no_encontrada}, State};
        {error, Motivo} ->
            {{error, Motivo}, State}
    end.

%% Si el usuario eligio una de las opciones mostradas, se intenta esa primero.
%% Solo se acepta si aparece en las opciones calculadas por el coordinador,
%% de modo que el cliente no pueda pedir un cajon arbitrario.
%% Tambien se usa para conservar el cajon anterior como primera opcion de su
%% zona cuando el alumno cambia de tarjeta.
preferir_objetivo(ObjetivoId, Opciones) when not is_binary(ObjetivoId) ->
    Opciones;
preferir_objetivo(<<>>, Opciones) ->
    Opciones;
preferir_objetivo(ObjetivoId, Opciones) ->
    case lists:partition(
           fun(O) -> maps:get(cajon_id, O) =:= ObjetivoId end, Opciones) of
        {[Elegida], Resto} -> [Elegida | Resto];
        _ -> Opciones
    end.

confirmar_respuesta(ReservaId, CajonId) ->
    case reserva_valida(ReservaId, CajonId) of
        {error, Motivo} ->
            {error, Motivo};
        {ok, Zona} ->
            case intentar_zona(fun() ->
                                   p49_zona:confirmar(Zona, CajonId, ReservaId)
                               end) of
                ok ->
                    {ok, #{reserva_id => ReservaId, cajon_id => CajonId,
                           estado => confirmada,
                           mensaje => <<"Reserva confirmada. Presentate dentro del horario indicado.">>}};
                {error, Motivo} ->
                    {error, Motivo}
            end
    end.

cancelar_respuesta(ReservaId, CajonId) ->
    case reserva_valida(ReservaId, CajonId) of
        {error, Motivo} ->
            {error, Motivo};
        {ok, Zona} ->
            case intentar_zona(fun() ->
                                   p49_zona:cancelar(
                                     Zona, CajonId, ReservaId,
                                     <<"Cancelada por el usuario">>)
                               end) of
                ok -> {ok, #{reserva_id => ReservaId, estado => cancelada}};
                {error, Motivo} -> {error, Motivo}
            end
    end.

%% ------------------------------------------------------------------
%% Entrada y salida del estacionamiento
%% ------------------------------------------------------------------

%% Registrar la entrada exige una reserva confirmada. El cajon se puede
%% indicar explicitamente (la interfaz lo hace) o dejar que el coordinador
%% busque el cajon confirmado de la placa. Nunca se elige un cajon libre
%% arbitrario: eso respeta la asignacion automatica del proyecto.
entrada_respuesta(Placa, CajonId) ->
    PlacaLimpia = p49_util:limpiar_placa(Placa),
    case p49_config:placa_valida(PlacaLimpia) of
        false ->
            {error, placa_invalida};
        true ->
            case es_texto(CajonId) of
                true -> entrada_en_cajon(PlacaLimpia, CajonId);
                false -> entrada_sin_cajon(PlacaLimpia)
            end
    end.

entrada_en_cajon(Placa, CajonId) ->
    case detalle_reserva(CajonId) of
        {ok, #{estado := ocupado, reserva := Reserva} = Detalle} ->
            case maps:get(placa, Reserva, undefined) of
                Placa -> {ok, publico(detalle_publico(CajonId, Detalle), Placa,
                                      #{ya_registrada => true})};
                _ -> {error, placa_no_coincide}
            end;
        {ok, #{estado := reservado, reserva := Reserva}} ->
            case {maps:get(placa, Reserva, undefined),
                  maps:get(confirmada, Reserva, false)} of
                {Placa, true} -> ocupar_en_cajon(Placa, CajonId);
                {Placa, false} -> {error, reserva_no_confirmada};
                _ -> {error, placa_no_coincide}
            end;
        {ok, #{estado := fuera_servicio}} ->
            {error, cajon_fuera_de_servicio};
        {ok, _} ->
            {error, sin_reserva_confirmada};
        {error, Motivo} ->
            {error, Motivo}
    end.

entrada_sin_cajon(Placa) ->
    Reservas = reservas_de_placa(Placa),
    case [R || R <- Reservas, maps:get(estado, R) =:= ocupado] of
        [Ocupada | _] ->
            {ok, publico(Ocupada, Placa, #{ya_registrada => true})};
        [] ->
            case [R || R <- Reservas,
                       maps:get(estado, R) =:= reservado,
                       maps:get(confirmada, R, false)] of
                [Confirmada | _] ->
                    ocupar_en_cajon(Placa, maps:get(cajon_id, Confirmada));
                [] ->
                    case [R || R <- Reservas,
                               maps:get(estado, R) =:= reservado] of
                        [] -> {error, sin_reserva_confirmada};
                        _ -> {error, reserva_no_confirmada}
                    end
            end
    end.

ocupar_en_cajon(Placa, CajonId) ->
    Zona = p49_config:zona_de_cajon(CajonId),
    case intentar_zona(fun() -> p49_zona:ocupar(Zona, CajonId, Placa) end) of
        {ok, Info} -> {ok, publico(Info, Placa, #{})};
        {error, Motivo} -> {error, Motivo}
    end.

%% La salida solo libera el cajon que realmente ocupa esa placa. Si se envia
%% el cajon, se valida; si no, se busca el unico cajon ocupado de la placa.
salida_respuesta(Placa, CajonId) ->
    PlacaLimpia = p49_util:limpiar_placa(Placa),
    case p49_config:placa_valida(PlacaLimpia) of
        false ->
            {error, placa_invalida};
        true ->
            case es_texto(CajonId) of
                true -> salida_en_cajon(PlacaLimpia, CajonId);
                false -> salida_sin_cajon(PlacaLimpia)
            end
    end.

salida_en_cajon(Placa, CajonId) ->
    case detalle_reserva(CajonId) of
        {ok, #{estado := ocupado, reserva := Reserva}} ->
            case maps:get(placa, Reserva, undefined) of
                Placa -> liberar_en_cajon(Placa, CajonId);
                _ -> {error, placa_no_coincide}
            end;
        {ok, #{estado := reservado, reserva := Reserva}} ->
            case maps:get(placa, Reserva, undefined) of
                Placa -> {error, sin_estacionamiento_activo};
                _ -> {error, placa_no_coincide}
            end;
        {ok, _} ->
            {error, sin_estacionamiento_activo};
        {error, Motivo} ->
            {error, Motivo}
    end.

salida_sin_cajon(Placa) ->
    Reservas = reservas_de_placa(Placa),
    case [R || R <- Reservas, maps:get(estado, R) =:= ocupado] of
        [Ocupada | _] -> liberar_en_cajon(Placa, maps:get(cajon_id, Ocupada));
        [] -> {error, sin_estacionamiento_activo}
    end.

liberar_en_cajon(Placa, CajonId) ->
    Zona = p49_config:zona_de_cajon(CajonId),
    case intentar_zona(fun() -> p49_zona:salida(Zona, CajonId, Placa) end) of
        {ok, Info} -> {ok, publico(Info, Placa, #{})};
        {error, Motivo} -> {error, Motivo}
    end.

estado_placa_respuesta(Placa) ->
    PlacaLimpia = p49_util:limpiar_placa(Placa),
    case p49_config:placa_valida(PlacaLimpia) of
        false ->
            {error, placa_invalida};
        true ->
            Reservas = reservas_de_placa(PlacaLimpia),
            Elegida = elegir_reserva(Reservas),
            case Elegida of
                undefined ->
                    {ok, #{activo => false, placa => PlacaLimpia,
                           estado => <<"libre">>,
                           mensaje => <<"La placa no tiene un cajon activo">>}};
                R ->
                    {ok, publico(R, PlacaLimpia, #{})}
            end
    end.

elegir_reserva(Reservas) ->
    Prioridad = [ocupado, reservado],
    elegir_reserva(Reservas, Prioridad).

elegir_reserva(_Reservas, []) ->
    undefined;
elegir_reserva(Reservas, [Estado | Resto]) ->
    case [R || R <- Reservas, maps:get(estado, R) =:= Estado] of
        [R | _] -> R;
        [] -> elegir_reserva(Reservas, Resto)
    end.

detalle_publico(CajonId, Detalle) ->
    Reserva = maps:get(reserva, Detalle, undefined),
    Zona = p49_config:zona_de_cajon(CajonId),
    #{zona => Zona,
      zona_nombre => nombre_zona(Zona),
      cajon_id => CajonId,
      numero => maps:get(numero, Detalle, p49_config:numero_de_cajon(CajonId)),
      tipo => maps:get(tipo, Detalle, undefined),
      estado => maps:get(estado, Detalle, libre),
      reserva_id => reserva_campo(id, Reserva, undefined),
      placa => reserva_campo(placa, Reserva, undefined),
      confirmada => reserva_campo(confirmada, Reserva, false),
      entrada_en => reserva_campo(entrada_en, Reserva, undefined),
      expira_en => reserva_campo(expira_en, Reserva, undefined)}.

reserva_campo(Clave, Reserva, Default) when is_map(Reserva) ->
    maps:get(Clave, Reserva, Default);
reserva_campo(_Clave, _Reserva, Default) ->
    Default.

%% Convierte los datos internos (atoms) en una respuesta estable para la API.
publico(Info, Placa, Extra) ->
    Estado = maps:get(estado, Info, libre),
    Activo = Estado =:= reservado orelse Estado =:= ocupado,
    maps:merge(
      #{activo => Activo,
        placa => Placa,
        zona => maps:get(zona, Info, undefined),
        zona_nombre => maps:get(zona_nombre, Info, undefined),
        cajon_id => maps:get(cajon_id, Info, undefined),
        numero => maps:get(numero, Info, undefined),
        tipo => maps:get(tipo, Info, undefined),
        reserva_id => maps:get(reserva_id, Info, undefined),
        estado => p49_util:bin(Estado),
        confirmada => maps:get(confirmada, Info, false),
        entrada_en => maps:get(entrada_en, Info, undefined),
        salida_en => maps:get(salida_en, Info, undefined),
        duracion_seg => maps:get(duracion_seg, Info, undefined),
        expira_en => maps:get(expira_en, Info, undefined),
        puede_entrar => Estado =:= reservado andalso
            maps:get(confirmada, Info, false),
        puede_salir => Estado =:= ocupado},
      Extra).

nombre_zona(ZonaId) ->
    case p49_config:zona(ZonaId) of
        {ok, Zona} -> maps:get(nombre, Zona);
        _ -> <<"Estacionamiento">>
    end.

%% Valida identificadores antes de llamar a una zona. Sin esto una peticion
%% HTTP con id vacio intentaria contactar un proceso inexistente y tumbaria
%% al coordinador.
reserva_valida(ReservaId, CajonId) ->
    case es_texto(ReservaId) of
        false ->
            {error, reserva_no_encontrada};
        true ->
            zona_valida(CajonId)
    end.

zona_valida(CajonId) ->
    case es_texto(CajonId) of
        false ->
            {error, cajon_no_encontrado};
        true ->
            Zona = p49_config:zona_de_cajon(CajonId),
            case p49_config:zona(Zona) of
                {ok, _} -> {ok, Zona};
                {error, _} -> {error, cajon_no_encontrado}
            end
    end.

es_texto(Valor) when is_binary(Valor) -> byte_size(Valor) > 0;
es_texto(_) -> false.

intentar_zona(Fun) ->
    try Fun()
    catch
        exit:{noproc, _} -> {error, servicio_no_disponible};
        exit:{timeout, _} -> {error, servicio_no_disponible};
        _:_ -> {error, servicio_no_disponible}
    end.

validar_solicitud(EdificioId, Tipo, Placa) ->
    PlacaLimpia = p49_util:limpiar_placa(Placa),
    case p49_config:edificio(EdificioId) of
        {error, _} -> {error, edificio_no_encontrado};
        {ok, Edificio} ->
            case p49_config:tipo_valido(Tipo) of
                false -> {error, tipo_usuario_invalido};
                true ->
                    case p49_config:placa_valida(PlacaLimpia) of
                        false -> {error, placa_invalida};
                        true -> {ok, Edificio}
                    end
            end
    end.

sostener([], _Placa, _Edificio, _Excluir) ->
    {error, sin_disponibilidad};
sostener([Opcion | Resto], Placa, Edificio, Excluir) ->
    Zona = maps:get(zona, Opcion),
    CajonId = maps:get(cajon_id, Opcion),
    ReservaId = p49_util:id("res"),
    case p49_zona:reservar(Zona, CajonId, ReservaId, Placa, Edificio) of
        {ok, Info} ->
            {ok, Info, Resto};
        {error, _Motivo} ->
            %% La recomendacion pudo quedar obsoleta entre la consulta y la
            %% reserva. Se intenta la siguiente sin elegir un cajon arbitrario.
            sostener(Resto, Placa, Edificio, [CajonId | Excluir])
    end.

respuesta_recomendacion(Info, Restantes, Edificio, Tipo) ->
    Cajon = #{id => maps:get(cajon_id, Info),
              numero => maps:get(numero, Info),
              zona => maps:get(zona, Info),
              zona_nombre => maps:get(zona_nombre, Info),
              tipo => maps:get(tipo, Info),
              distancia => p49_config:distancia(
                             maps:get(edificio, Info), maps:get(zona, Info))},
    Alternativas = [formatear_opcion(O) || O <- Restantes],
    #{reserva_id => maps:get(reserva_id, Info),
      placa => maps:get(placa, Info),
      edificio => maps:get(edificio, Info),
      edificio_nombre => maps:get(nombre, Edificio),
      tipo_usuario => Tipo,
      cajon => Cajon,
      alternativas => Alternativas,
      expira_en => maps:get(expira_en, Info),
      generado_en => p49_util:ahora_seg(),
      mensaje => <<"Cajon asignado automaticamente. Confirma para conservarlo.">>}.

formatear_opcion(Opcion) ->
    #{zona => maps:get(zona, Opcion),
      zona_nombre => maps:get(zona_nombre, Opcion),
      cajon_id => maps:get(cajon_id, Opcion),
      numero => maps:get(numero, Opcion),
      tipo => maps:get(tipo, Opcion),
      distancia => maps:get(distancia, Opcion),
      score => maps:get(score, Opcion)}.

detalle_reserva(CajonId) ->
    case zona_valida(CajonId) of
        {ok, Zona} ->
            try p49_zona:detalle(Zona, CajonId)
            catch _:_ -> {error, servicio_no_disponible}
            end;
        {error, Motivo} ->
            {error, Motivo}
    end.

tipo_para_alternativa(Tipo, _TipoCajon) ->
    case p49_config:tipo_valido(Tipo) of
        true -> Tipo;
        false -> <<"alumno">>
    end.

opciones(EdificioId, Tipo, Excluir) ->
    Recomendadas = p49_config:zonas_recomendadas(EdificioId),
    Preferidas = opciones_de_zonas(Recomendadas, EdificioId, Tipo, Excluir),
    case Preferidas of
        [] -> opciones_de_zonas(ids_zonas(), EdificioId, Tipo, Excluir);
        _ -> Preferidas
    end.

%% Agrupa las opciones por zona, ordena cada grupo y los intercala. Asi, si
%% los dos estacionamientos recomendados tienen disponibilidad, las dos
%% primeras opciones son de zonas distintas: el alumno ve un cajon por
%% estacionamiento y elige entre ellos, sin poder pedir un cajon arbitrario.
opciones_de_zonas(Zonas, EdificioId, Tipo, Excluir) ->
    Grupos = [Grupo || ZonaId <- Zonas,
                       Grupo <- [opciones_zona(ZonaId, EdificioId, Tipo,
                                               Excluir)],
                       Grupo =/= []],
    Intercaladas = intercalar(ordenar_grupos(Grupos)),
    lists:sublist(Intercaladas, 6).

opciones_zona(ZonaId, EdificioId, Tipo, Excluir) ->
    Resumen = safe_resumen(ZonaId),
    case maps:get(abierto, Resumen, false) of
        false -> [];
        true ->
            Recos = safe_recomendar(ZonaId, EdificioId, Tipo),
            Distancia = p49_config:distancia(EdificioId, ZonaId),
            Presion = maps:get(presion, Resumen, 0),
            Porcentaje = maps:get(porcentaje_ocupacion, Resumen, 100.0),
            Rank = Distancia * 10.0 + Presion * 2.5 + Porcentaje * 0.35,
            Opciones = [O#{score_total => p49_util:redondear(
                                         Rank + maps:get(score, O)),
                           distancia => Distancia}
                        || O <- Recos,
                           not lists:member(maps:get(cajon_id, O), Excluir)],
            lists:sort(
              fun(A, B) ->
                      maps:get(score_total, A) =< maps:get(score_total, B)
              end, Opciones)
    end.

ordenar_grupos(Grupos) ->
    lists:sort(
      fun([A | _], [B | _]) ->
              maps:get(score_total, A) =< maps:get(score_total, B)
      end, Grupos).

intercalar(Grupos) ->
    intercalar(Grupos, []).

intercalar(Grupos, Acc) ->
    Vivos = [G || G <- Grupos, G =/= []],
    case Vivos of
        [] -> lists:reverse(Acc);
        _ ->
            Heads = [hd(G) || G <- Vivos],
            Restos = [tl(G) || G <- Vivos],
            intercalar(Restos, lists:reverse(Heads) ++ Acc)
    end.

%% ------------------------------------------------------------------
%% Administracion
%% ------------------------------------------------------------------

admin_cajones_respuesta(ZonaId) ->
    case p49_config:zona(ZonaId) of
        {error, Motivo} -> {error, Motivo};
        {ok, ZonaCfg} ->
            Resumen = safe_resumen(ZonaId),
            {ok, #{zona => ZonaId,
                   nombre => maps:get(nombre, ZonaCfg),
                   abierto => maps:get(abierto, Resumen, false),
                   total => maps:get(total, Resumen, 0),
                   cajones => safe_cajones_admin(ZonaId)}}
    end.

admin_zona_estado_respuesta(ZonaId, Estado) ->
    case p49_config:zona(ZonaId) of
        {error, Motivo} -> {error, Motivo};
        {ok, _} ->
            Resultado = case Estado of
                            <<"cerrado">> ->
                                intentar_zona(fun() -> p49_zona:cerrar(ZonaId) end);
                            <<"abierto">> ->
                                intentar_zona(fun() -> p49_zona:abrir(ZonaId) end);
                            _ -> {error, estado_invalido}
                        end,
            case Resultado of
                ok -> {ok, safe_resumen(ZonaId)};
                {error, Motivo} -> {error, Motivo}
            end
    end.

admin_cajon_estado_respuesta(CajonId, Estado, Motivo) ->
    Zona = p49_config:zona_de_cajon(CajonId),
    case p49_config:zona(Zona) of
        {error, Error} -> {error, Error};
        {ok, _} ->
            case Estado of
                <<"fuera_servicio">> ->
                    intentar_zona(fun() ->
                                      p49_zona:fuera_servicio(Zona, CajonId, Motivo)
                                  end);
                <<"libre">> ->
                    intentar_zona(fun() -> p49_zona:habilitar(Zona, CajonId) end);
                _ ->
                    {error, estado_invalido}
            end
    end.

admin_cajon_liberar_respuesta(CajonId, Motivo) ->
    Zona = p49_config:zona_de_cajon(CajonId),
    case p49_config:zona(Zona) of
        {error, Error} -> {error, Error};
        {ok, _} ->
            intentar_zona(fun() -> p49_zona:liberar(Zona, CajonId, Motivo) end)
    end.

%% ------------------------------------------------------------------
%% Consultas y soporte
%% ------------------------------------------------------------------

resumenes_zonas() ->
    [safe_resumen(ZonaId) || ZonaId <- ids_zonas()].

safe_resumen(ZonaId) ->
    try p49_zona:resumen(ZonaId)
    catch
        _:_ -> resumen_defecto(ZonaId)
    end.

safe_recomendar(ZonaId, EdificioId, Tipo) ->
    try p49_zona:recomendar(ZonaId, EdificioId, Tipo)
    catch
        _:_ -> []
    end.

%% Una placa solo puede tener un cajon en todo el campus. Si la placa tiene
%% una reserva temporal sin confirmar, una nueva solicitud la reemplaza (por
%% ejemplo al refrescar la pagina o cambiar de tarjeta). Una reserva ya
%% confirmada o un cajon ocupado bloquean la nueva solicitud. El coordinador
%% serializa las peticiones, asi que revision y reserva no compiten.
liberar_reservas_temporales(Placa) ->
    Reservas = reservas_de_placa(Placa),
    case lists:any(fun(#{confirmada := Confirmada}) -> Confirmada end,
                   Reservas) of
        true ->
            {error, placa_ya_reservada};
        false ->
            lists:foreach(fun cancelar_reserva_temporal/1, Reservas),
            %% Si una zona no respondio o el cajon no pudo liberarse, no se
            %% crea una segunda reserva para la misma placa.
            case reservas_de_placa(Placa) of
                [] -> ok;
                _ -> {error, placa_ya_reservada}
            end
    end.

reservas_de_placa(Placa) ->
    lists:flatmap(fun(ZonaId) -> safe_reservas_de_placa(ZonaId, Placa) end,
                  ids_zonas()).

safe_reservas_de_placa(ZonaId, Placa) ->
    try p49_zona:reservas_de_placa(ZonaId, Placa)
    catch
        _:_ -> []
    end.

cancelar_reserva_temporal(#{zona := Zona, cajon_id := CajonId,
                            reserva_id := ReservaId})
  when is_binary(ReservaId) ->
    try p49_zona:cancelar(Zona, CajonId, ReservaId,
                          <<"Reemplazo de recomendacion">>)
    catch
        _:_ -> ok
    end;
cancelar_reserva_temporal(_) ->
    ok.

safe_cajones(ZonaId) ->
    try p49_zona:cajones(ZonaId)
    catch
        _:_ -> []
    end.

safe_cajones_admin(ZonaId) ->
    try p49_zona:cajones_admin(ZonaId)
    catch
        _:_ -> []
    end.

resumen_defecto(ZonaId) ->
    Nombre = case p49_config:zona(ZonaId) of
                 {ok, Z} -> maps:get(nombre, Z);
                 _ -> <<"Zona">>
             end,
    #{zona => ZonaId, nombre => Nombre, abierto => false, total => 375,
      libres => 0, reservados => 0, ocupados => 0, fuera_servicio => 0,
      porcentaje_ocupacion => 100.0, presion => 0,
      actualizado_en => p49_util:ahora_seg()}.

ids_zonas() ->
    [maps:get(id, Z) || Z <- p49_config:zonas()].

totales(Zonas) ->
    Total = suma(total, Zonas),
    Libres = suma(libres, Zonas),
    Reservados = suma(reservados, Zonas),
    Ocupados = suma(ocupados, Zonas),
    Fuera = suma(fuera_servicio, Zonas),
    Porcentaje = case Total of
                     0 -> 0.0;
                     _ -> p49_util:redondear(
                            (Ocupados + Reservados) * 100.0 / Total)
                 end,
    #{total => Total, libres => Libres, reservados => Reservados,
      ocupados => Ocupados, fuera_servicio => Fuera,
      porcentaje_ocupacion => Porcentaje,
      zonas_abiertas => length([1 || Z <- Zonas, maps:get(abierto, Z, false)])}.

suma(Clave, Zonas) ->
    lists:sum([maps:get(Clave, Z, 0) || Z <- Zonas]).

diagnostico_respuesta(State) ->
    Top = case catch recon:proc_count(memory, 5) of
              Lista when is_list(Lista) ->
                  [entrada_proceso(X) || X <- Lista];
              _ -> []
          end,
    MemAlloc = case catch recon_alloc:memory(used) of
                   N when is_integer(N) -> N;
                   _ -> 0
               end,
    #{nodo => p49_util:bin(node()),
      otp => p49_util:bin(erlang:system_info(otp_release)),
      uptime_seg => p49_util:ahora_seg() - maps:get(inicio, State),
      procesos => erlang:system_info(process_count),
      run_queue => erlang:statistics(run_queue),
      memoria_total => erlang:memory(total),
      memoria_alloc => MemAlloc,
      top_procesos => Top}.

%% recon:proc_count/2 devuelve {Pid, Memoria, Info} en OTP recientes y
%% {Pid, Memoria} en versiones anteriores. La API debe tolerar ambas.
entrada_proceso({Pid, Memoria, Info}) when is_pid(Pid) ->
    #{proceso => p49_util:bin(pid_to_list(Pid)),
      memoria => Memoria,
      info => p49_util:bin(io_lib:format("~p", [Info]))};
entrada_proceso({Pid, Memoria}) when is_pid(Pid) ->
    #{proceso => p49_util:bin(pid_to_list(Pid)), memoria => Memoria};
entrada_proceso(Otro) ->
    #{valor => p49_util:bin(Otro)}.
