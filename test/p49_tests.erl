%% Pruebas de dominio del proyecto 49.
%%
%% Se arranca el arbol de supervision real con la siembra desactivada y sin
%% abrir el listener HTTP. Asi los conteos son deterministas y las pruebas no
%% chocan con un servidor de desarrollo en el puerto 8080.
-module(p49_tests).
-include_lib("eunit/include/eunit.hrl").

-define(APP, p49_estacionamiento_del_campus).
-define(SERVER, p49_estacionamiento_del_campus_server).

p49_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [fun catalogo_integro/0,
      fun json_ida_y_vuelta/0,
      fun flujo_alumno/0,
      fun recomendaciones_variadas/0,
      fun entrada_y_salida/0,
      fun alternativa_y_cancelacion/0,
      fun alternativa_estable/0,
      fun validaciones_de_solicitud/0,
      fun placa_unica_en_el_campus/0,
      fun concurrencia_sin_duplicados/0,
      fun admin_pin_y_token/0,
      fun admin_zonas_y_cajones/0,
      fun admin_placa_y_liberacion/0,
      fun reserva_expira/0,
      fun caos_zona_y_cajon/0,
      fun caos_coordinador/0,
      fun simulacion_concurrente/0]}.

%% ------------------------------------------------------------------
%% Fixture
%% ------------------------------------------------------------------

setup() ->
    application:load(?APP),
    application:set_env(?APP, seed_ocupacion, false),
    application:set_env(?APP, http_enabled, false),
    application:set_env(?APP, reserva_ttl_seg, 600),
    {ok, _} = application:ensure_all_started(crypto),
    case whereis(p49_estacionamiento_del_campus_sup) of
        undefined ->
            {ok, Sup} = p49_estacionamiento_del_campus_sup:start_link(),
            unlink(Sup),
            #{sup => Sup, propio => true};
        Sup ->
            #{sup => Sup, propio => false}
    end.

cleanup(#{sup := Sup, propio := true}) ->
    Ref = monitor(process, Sup),
    proc_lib:stop(Sup, shutdown, 60000),
    receive {'DOWN', Ref, process, Sup, _} -> ok after 5000 -> ok end,
    ok;
cleanup(_) ->
    ok.

%% ------------------------------------------------------------------
%% Catalogo y utilidades
%% ------------------------------------------------------------------

catalogo_integro() ->
    Edificios = p49_config:edificios(),
    Zonas = p49_config:zonas(),
    ?assertEqual(6, length(Edificios)),
    ?assertEqual(4, length(Zonas)),
    ?assertEqual(1500, p49_config:total_cajones()),
    ?assertEqual([<<"Z1">>, <<"Z2">>],
                 p49_config:zonas_recomendadas(<<"E1">>)),
    ?assertEqual(10, p49_config:distancia(<<"E1">>, <<"Z4">>)),
    ?assertEqual(10, p49_config:distancia(<<"NO-EXISTE">>, <<"Z1">>)),

    Ids = lists:flatmap(
            fun(Zona) ->
                [maps:get(id, C) ||
                 C <- p49_config:cajones_zona(maps:get(id, Zona))]
            end, Zonas),
    ?assertEqual(1500, length(Ids)),
    ?assertEqual(1500, length(lists:usort(Ids))),
    ?assertEqual(375, length(p49_config:cajones_zona(<<"Z1">>))),

    ?assertEqual(<<"Z1-001">>, p49_config:cajon_id(<<"Z1">>, 1)),
    ?assertEqual(<<"Z1-001">>, p49_config:cajon_id(<<"Z1">>, 1)),
    ?assertEqual(<<"Z1">>, p49_config:zona_de_cajon(<<"Z1-001">>)),
    ?assertEqual(1, p49_config:numero_de_cajon(<<"Z1-001">>)),
    ?assertEqual(0, p49_config:numero_de_cajon(<<"sin-guion">>)),
    ?assertEqual(0, p49_config:numero_de_cajon(<<"Z1-xx">>)),

    ?assert(p49_config:placa_valida(<<"ABC-123">>)),
    ?assertNot(p49_config:placa_valida(<<"ab">>)),
    ?assertNot(p49_config:placa_valida(<<"ABC 123">>)),
    ?assertNot(p49_config:placa_valida(<<"ABC_123">>)),

    ?assert(p49_config:tipo_valido(<<"moto">>)),
    ?assertNot(p49_config:tipo_valido(<<"normal">>)),
    ?assertEqual([<<"alumno">>, <<"visitante">>],
                 p49_config:tipos_compatibles(<<"alumno">>)),
    ?assertEqual([<<"discapacidad">>],
                 p49_config:tipos_compatibles(<<"discapacidad">>)),

    Catalogo = ?SERVER:catalogo(),
    Resumen = maps:get(resumen, Catalogo),
    ?assertEqual(1500, maps:get(total, Resumen)),
    ?assertEqual(1500, maps:get(libres, Resumen)),
    ?assertEqual(0, maps:get(ocupados, Resumen)),
    ?assertEqual(4, maps:get(zonas_abiertas, Resumen)),
    ?assertEqual(6, length(maps:get(edificios, Catalogo))),
    ?assertEqual(5, length(maps:get(tipos_usuario, Catalogo))).

json_ida_y_vuelta() ->
    Original = #{<<"texto">> => <<"Jose / linea\n\"citada\"">>,
                 <<"lista">> => [1, -2, 2.5, true, false, null],
                 <<"objeto">> => #{<<"acentos">> => <<"estacionamiento">>,
                                   <<"emoji">> => <<"campus">>}},
    Binario = p49_json:encode(Original),
    ?assert(is_binary(Binario)),
    ?assertEqual({ok, Original}, p49_json:decode(Binario)),

    ?assertEqual({ok, #{<<"a">> => <<"é"/utf8>>}},
                 p49_json:decode(<<"{\"a\":\"\\u00e9\"}">>)),
    ?assertEqual({ok, [1, 2, 3]}, p49_json:decode(<<" [1,2,3] ">>)),
    ?assertEqual({ok, #{}}, p49_json:decode(<<"{}">>)),
    ?assertEqual({error, json_invalido}, p49_json:decode(<<"{">>)),
    ?assertEqual({error, json_invalido}, p49_json:decode(<<"{\"a\":1} basura">>)),
    ?assertEqual({error, json_invalido}, p49_json:decode(<<"no-json">>)),
    ?assertEqual({error, json_invalido}, p49_json:decode(123)).

%% ------------------------------------------------------------------
%% Flujo del alumno
%% ------------------------------------------------------------------

flujo_alumno() ->
    {ok, Mapa} = ?SERVER:mapa(<<"E1">>),
    ?assertEqual([<<"Z1">>, <<"Z2">>], maps:get(recomendadas, Mapa)),
    ?assertEqual(4, length(maps:get(zonas, Mapa))),
    ?assert(lists:all(
              fun(Zona) -> length(maps:get(cajones, Zona)) =:= 375 end,
              maps:get(zonas, Mapa))),

    {ok, Recomendacion} = ?SERVER:recomendar(<<"E1">>, <<"alumno">>,
                                             <<"abc-123">>),
    ?assertEqual(<<"ABC-123">>, maps:get(placa, Recomendacion)),
    ?assertEqual(<<"E1">>, maps:get(edificio, Recomendacion)),
    ?assertEqual(<<"alumno">>, maps:get(tipo_usuario, Recomendacion)),
    Cajon = maps:get(cajon, Recomendacion),
    CajonId = maps:get(id, Cajon),
    Zona = maps:get(zona, Cajon),
    ?assert(lists:member(Zona, [<<"Z1">>, <<"Z2">>])),
    ?assertEqual(Zona, p49_config:zona_de_cajon(CajonId)),

    Alternativas = maps:get(alternativas, Recomendacion),
    ?assert(length(Alternativas) > 0),
    ?assert(lists:all(fun(A) ->
                              lists:member(maps:get(zona, A),
                                           [<<"Z1">>, <<"Z2">>])
                      end, Alternativas)),
    %% Con ambos estacionamientos recomendados disponibles, la primera
    %% alternativa debe ser del otro, para ofrecer una opcion por zona.
    [PrimeraAlternativa | _] = Alternativas,
    ?assertNotEqual(Zona, maps:get(zona, PrimeraAlternativa)),

    ReservaId = maps:get(reserva_id, Recomendacion),
    {ok, Detalle} = p49_zona:detalle(Zona, CajonId),
    ?assertEqual(reservado, maps:get(estado, Detalle)),
    ?assertEqual(ReservaId, maps:get(id, maps:get(reserva, Detalle))),

    %% Confirmar con un identificador ajeno no debe tocar la reserva.
    ?assertEqual({error, reserva_no_encontrada},
                 ?SERVER:confirmar(<<"res-inventada">>, CajonId)),

    {ok, Confirmada} = ?SERVER:confirmar(ReservaId, CajonId),
    ?assertEqual(confirmada, maps:get(estado, Confirmada)),
    ?assertEqual(ReservaId, maps:get(reserva_id, Confirmada)),

    {ok, DetalleConfirmado} = p49_zona:detalle(Zona, CajonId),
    ReservaConfirmada = maps:get(reserva, DetalleConfirmado),
    ?assertEqual(true, maps:get(confirmada, ReservaConfirmada)),
    ?assert(maps:get(expira_en, ReservaConfirmada) > p49_util:ahora_seg()),

    {ok, Cancelada} = ?SERVER:cancelar(ReservaId, CajonId),
    ?assertEqual(cancelada, maps:get(estado, Cancelada)),
    {ok, DetalleLibre} = p49_zona:detalle(Zona, CajonId),
    ?assertEqual(libre, maps:get(estado, DetalleLibre)).

%% El desempate del costo depende del edificio y la zona. Sin eso, con el
%% campus vacio todas las zonas recomendaban el mismo numero (222).
recomendaciones_variadas() ->
    [E1Z1 | _] = p49_zona:recomendar(<<"Z1">>, <<"E1">>, <<"alumno">>),
    [E2Z1 | _] = p49_zona:recomendar(<<"Z1">>, <<"E2">>, <<"alumno">>),
    [E5Z1 | _] = p49_zona:recomendar(<<"Z1">>, <<"E5">>, <<"alumno">>),
    Numeros = [maps:get(numero, O) || O <- [E1Z1, E2Z1, E5Z1]],
    ?assert(length(lists:usort(Numeros)) > 1),

    {ok, RE1} = ?SERVER:recomendar(<<"E1">>, <<"alumno">>, <<"VAR-001">>),
    {ok, RE5} = ?SERVER:recomendar(<<"E5">>, <<"alumno">>, <<"VAR-002">>),
    N1 = maps:get(numero, maps:get(cajon, RE1)),
    N5 = maps:get(numero, maps:get(cajon, RE5)),
    ?assertNotEqual(N1, N5),
    {ok, _} = ?SERVER:cancelar(maps:get(reserva_id, RE1),
                               maps:get(id, maps:get(cajon, RE1))),
    {ok, _} = ?SERVER:cancelar(maps:get(reserva_id, RE5),
                               maps:get(id, maps:get(cajon, RE5))).

entrada_y_salida() ->
    {ok, R} = ?SERVER:recomendar(<<"E5">>, <<"alumno">>, <<"ENT-001">>),
    CajonId = maps:get(id, maps:get(cajon, R)),
    Zona = maps:get(zona, maps:get(cajon, R)),
    ReservaId = maps:get(reserva_id, R),

    %% No se puede entrar con una recomendacion temporal sin confirmar.
    ?assertEqual({error, reserva_no_confirmada},
                 ?SERVER:entrada(<<"ENT-001">>, CajonId)),
    {ok, _} = ?SERVER:confirmar(ReservaId, CajonId),

    %% Solo la placa que reservo puede ocupar el cajon.
    ?assertEqual({error, placa_no_coincide},
                 ?SERVER:entrada(<<"OTR-999">>, CajonId)),

    {ok, Dentro} = ?SERVER:entrada(<<"ent-001">>, CajonId),
    ?assertEqual(<<"ocupado">>, maps:get(estado, Dentro)),
    ?assertEqual(true, maps:get(activo, Dentro)),
    ?assertEqual(true, maps:get(puede_salir, Dentro)),
    ?assertEqual(false, maps:get(puede_entrar, Dentro)),
    ?assert(is_integer(maps:get(entrada_en, Dentro))),

    {ok, Detalle} = p49_zona:detalle(Zona, CajonId),
    ?assertEqual(ocupado, maps:get(estado, Detalle)),
    ?assertEqual(<<"ENT-001">>, maps:get(placa, maps:get(reserva, Detalle))),

    %% Registrar la entrada dos veces es idempotente.
    {ok, OtraVez} = ?SERVER:entrada(<<"ENT-001">>, CajonId),
    ?assertEqual(true, maps:get(ya_registrada, OtraVez)),

    %% Mientras esta ocupado no puede reservar otro cajon.
    ?assertEqual({error, placa_ya_reservada},
                 ?SERVER:recomendar(<<"E1">>, <<"alumno">>, <<"ENT-001">>)),

    {ok, Estado} = ?SERVER:estado_placa(<<"ENT-001">>),
    ?assertEqual(true, maps:get(activo, Estado)),
    ?assertEqual(<<"ocupado">>, maps:get(estado, Estado)),
    ?assertEqual(CajonId, maps:get(cajon_id, Estado)),

    %% La salida exige la misma placa y deja el cajon libre.
    ?assertEqual({error, placa_no_coincide},
                 ?SERVER:salida(<<"OTR-999">>, CajonId)),
    {ok, Fuera} = ?SERVER:salida(<<"ENT-001">>, CajonId),
    ?assertEqual(<<"libre">>, maps:get(estado, Fuera)),
    ?assertEqual(false, maps:get(activo, Fuera)),
    ?assert(maps:get(duracion_seg, Fuera) >= 0),
    {ok, Libre} = p49_zona:detalle(Zona, CajonId),
    ?assertEqual(libre, maps:get(estado, Libre)),
    ?assertEqual({error, sin_estacionamiento_activo},
                 ?SERVER:salida(<<"ENT-001">>, <<>>)),

    %% Tambien se puede omitir el cajon: el coordinador busca el de la placa.
    {ok, R2} = ?SERVER:recomendar(<<"E5">>, <<"docente">>, <<"ENT-002">>),
    Cajon2 = maps:get(id, maps:get(cajon, R2)),
    {ok, _} = ?SERVER:confirmar(maps:get(reserva_id, R2), Cajon2),
    {ok, Dentro2} = ?SERVER:entrada(<<"ENT-002">>, <<>>),
    ?assertEqual(Cajon2, maps:get(cajon_id, Dentro2)),
    ?assertEqual(<<"ocupado">>, maps:get(estado, Dentro2)),
    {ok, Fuera2} = ?SERVER:salida(<<"ENT-002">>, <<>>),
    ?assertEqual(Cajon2, maps:get(cajon_id, Fuera2)),
    ?assertEqual(<<"libre">>, maps:get(estado, Fuera2)),

    ?assertEqual({error, sin_reserva_confirmada},
                 ?SERVER:entrada(<<"SIN-001">>, <<>>)),
    ?assertEqual({error, placa_invalida},
                 ?SERVER:entrada(<<"!!">>, <<>>)).

alternativa_y_cancelacion() ->
    {ok, R1} = ?SERVER:recomendar(<<"E2">>, <<"alumno">>, <<"ALT-001">>),
    Cajon1 = maps:get(id, maps:get(cajon, R1)),
    Zona1 = maps:get(zona, maps:get(cajon, R1)),
    Reserva1 = maps:get(reserva_id, R1),
    [PrimeraAlternativa | _] = maps:get(alternativas, R1),
    ?assert(is_binary(maps:get(cajon_id, PrimeraAlternativa))),

    {ok, R2} = ?SERVER:alternativa(Reserva1, Cajon1, <<"alumno">>),
    Cajon2 = maps:get(id, maps:get(cajon, R2)),
    Zona2 = maps:get(zona, maps:get(cajon, R2)),
    Reserva2 = maps:get(reserva_id, R2),
    ?assert(Reserva1 =/= Reserva2),
    ?assert(Cajon1 =/= Cajon2),

    %% El cajon anterior se libera solo despues de sostener el nuevo.
    {ok, Anterior} = p49_zona:detalle(Zona1, Cajon1),
    ?assertEqual(libre, maps:get(estado, Anterior)),

    ?assertEqual({error, reserva_no_encontrada},
                 ?SERVER:cancelar(<<"res-ajena">>, Cajon2)),
    {ok, _} = ?SERVER:cancelar(Reserva2, Cajon2),
    {ok, Nuevo} = p49_zona:detalle(Zona2, Cajon2),
    ?assertEqual(libre, maps:get(estado, Nuevo)),

    %% Elegir explicitamente la segunda opcion (otra zona) la respeta.
    {ok, R3} = ?SERVER:recomendar(<<"E1">>, <<"alumno">>, <<"ALT-002">>),
    Cajon3 = maps:get(id, maps:get(cajon, R3)),
    Reserva3 = maps:get(reserva_id, R3),
    [Alt3 | _] = maps:get(alternativas, R3),
    Objetivo = maps:get(cajon_id, Alt3),
    ZonaObjetivo = maps:get(zona, Alt3),
    ?assertNotEqual(maps:get(zona, maps:get(cajon, R3)), ZonaObjetivo),
    {ok, R4} = ?SERVER:alternativa(Reserva3, Cajon3, <<"alumno">>, Objetivo),
    ?assertEqual(Objetivo, maps:get(id, maps:get(cajon, R4))),
    ?assertEqual(ZonaObjetivo, maps:get(zona, maps:get(cajon, R4))),
    {ok, _} = ?SERVER:cancelar(maps:get(reserva_id, R4), Objetivo),

    %% Un objetivo que el servidor no ofrecio (o incompatible) no se acepta.
    {ok, R5} = ?SERVER:recomendar(<<"E1">>, <<"alumno">>, <<"ALT-003">>),
    Cajon5 = maps:get(id, maps:get(cajon, R5)),
    {ok, R6} = ?SERVER:alternativa(maps:get(reserva_id, R5), Cajon5,
                                   <<"alumno">>, <<"Z1-311">>),
    Cajon6 = maps:get(id, maps:get(cajon, R6)),
    ?assertNotEqual(<<"Z1-311">>, Cajon6),
    ?assertNotEqual(<<"discapacidad">>, maps:get(tipo, maps:get(cajon, R6))),
    {ok, _} = ?SERVER:cancelar(maps:get(reserva_id, R6), Cajon6).

%% Al cambiar de tarjeta, la opcion que no se eligio debe conservar su cajon.
%% Antes se recalculaba antes de liberar el cajon anterior y saltaba a otro
%% numero en cada seleccion.
alternativa_estable() ->
    {ok, R1} = ?SERVER:recomendar(<<"E2">>, <<"alumno">>, <<"EST-001">>),
    C1 = maps:get(id, maps:get(cajon, R1)),
    Z1 = maps:get(zona, maps:get(cajon, R1)),
    [A1 | _] = maps:get(alternativas, R1),
    C2 = maps:get(cajon_id, A1),
    Z2 = maps:get(zona, A1),
    ?assertNotEqual(Z1, Z2),

    %% Elegir la alternativa: el cajon anterior queda libre y sigue siendo la
    %% otra opcion, en vez de aparecer un numero nuevo.
    {ok, R2} = ?SERVER:alternativa(maps:get(reserva_id, R1), C1,
                                   <<"alumno">>, C2),
    ?assertEqual(C2, maps:get(id, maps:get(cajon, R2))),
    Alternativas2 = maps:get(alternativas, R2),
    ?assertEqual(C1, maps:get(cajon_id,
                              hd([A || A <- Alternativas2,
                                       maps:get(zona, A) =:= Z1]))),

    %% Volver a la opcion original conserva la opcion intermedia.
    {ok, R3} = ?SERVER:alternativa(maps:get(reserva_id, R2), C2,
                                   <<"alumno">>, C1),
    ?assertEqual(C1, maps:get(id, maps:get(cajon, R3))),
    Alternativas3 = maps:get(alternativas, R3),
    ?assertEqual(C2, maps:get(cajon_id,
                              hd([A || A <- Alternativas3,
                                       maps:get(zona, A) =:= Z2]))),
    {ok, _} = ?SERVER:cancelar(maps:get(reserva_id, R3), C1).

validaciones_de_solicitud() ->
    ?assertEqual({error, edificio_no_encontrado},
                 ?SERVER:recomendar(<<"E9">>, <<"alumno">>, <<"ABC-123">>)),
    ?assertEqual({error, tipo_usuario_invalido},
                 ?SERVER:recomendar(<<"E1">>, <<"normal">>, <<"ABC-123">>)),
    ?assertEqual({error, placa_invalida},
                 ?SERVER:recomendar(<<"E1">>, <<"alumno">>, <<"!!">>)),
    ?assertEqual({error, reserva_no_encontrada},
                 ?SERVER:confirmar(<<>>, <<"Z1-001">>)),
    ?assertEqual({error, cajon_no_encontrado},
                 ?SERVER:confirmar(<<"res-1">>, <<>>)),
    ?assertEqual({error, cajon_no_encontrado},
                 ?SERVER:confirmar(<<"res-1">>, <<"ZZ-001">>)),
    ?assertEqual({error, cajon_no_encontrado},
                 ?SERVER:cancelar(<<"res-1">>, <<"ZZ-001">>)),
    ?assertEqual({error, zona_no_encontrada},
                 ?SERVER:admin_cajones(<<"ZZ">>)),
    ?assertEqual({error, zona_no_encontrada},
                 ?SERVER:admin_zona_estado(<<"ZZ">>, <<"cerrado">>)),
    ?assertMatch({ok, _}, ?SERVER:mapa(<<"E1">>)),
    ?assertEqual({error, edificio_no_encontrado},
                 ?SERVER:mapa(<<"E9">>)).

placa_unica_en_el_campus() ->
    %% Una reserva temporal de la misma placa se reemplaza: asi refrescar la
    %% pagina o cambiar de tarjeta no deja a la placa bloqueada.
    {ok, R1} = ?SERVER:recomendar(<<"E3">>, <<"alumno">>, <<"UNI-001">>),
    Cajon1 = maps:get(id, maps:get(cajon, R1)),
    Zona1 = maps:get(zona, maps:get(cajon, R1)),
    {ok, R2} = ?SERVER:recomendar(<<"E4">>, <<"alumno">>, <<"uni-001">>),
    ?assert(maps:get(reserva_id, R1) =/= maps:get(reserva_id, R2)),
    {ok, Anterior} = p49_zona:detalle(Zona1, Cajon1),
    ?assertEqual(libre, maps:get(estado, Anterior)),

    %% Una reserva confirmada si bloquea un segundo cajon para la placa.
    Cajon2 = maps:get(id, maps:get(cajon, R2)),
    Reserva2 = maps:get(reserva_id, R2),
    {ok, _} = ?SERVER:confirmar(Reserva2, Cajon2),
    ?assertEqual({error, placa_ya_reservada},
                 ?SERVER:recomendar(<<"E1">>, <<"alumno">>, <<"UNI-001">>)),
    {ok, _} = ?SERVER:cancelar(Reserva2, Cajon2).

%% ------------------------------------------------------------------
%% Concurrencia
%% ------------------------------------------------------------------

concurrencia_sin_duplicados() ->
    Total = 120,
    Padre = self(),
    [spawn(fun() ->
               Resultado = try
                               ?SERVER:recomendar(<<"E1">>, <<"alumno">>,
                                                  placa_concurrente(I))
                           catch
                               Clase:Razon -> {fallo, Clase, Razon}
                           end,
               Padre ! {recomendacion, self(), Resultado}
           end) || I <- lists:seq(1, Total)],
    Resultados = [receive
                      {recomendacion, _Pid, R} -> R
                  after 30000 ->
                      timeout
                  end || _ <- lists:seq(1, Total)],
    ?assertEqual([], [R || R <- Resultados, R =:= timeout]),
    Oks = [R || {ok, R} <- Resultados],
    ?assertEqual(Total, length(Oks)),
    Cajones = [maps:get(id, maps:get(cajon, R)) || R <- Oks],
    ?assertEqual(Total, length(lists:usort(Cajones))),
    Reservas = [{maps:get(zona, maps:get(cajon, R)),
                 maps:get(id, maps:get(cajon, R)),
                 maps:get(reserva_id, R)} || R <- Oks],
    [begin
         {ok, _} = ?SERVER:cancelar(ReservaId, CajonId)
     end || {_Zona, CajonId, ReservaId} <- Reservas],
    ok.

placa_concurrente(I) ->
    iolist_to_binary(io_lib:format("CON-~3..0B", [I])).

%% ------------------------------------------------------------------
%% Administracion
%% ------------------------------------------------------------------

admin_pin_y_token() ->
    Pin = p49_config:admin_pin(),
    ?assert(is_binary(Pin)),
    PinMalo = case Pin of
                  <<"999999">> -> <<"000000">>;
                  _ -> <<"999999">>
              end,
    ?assertEqual({error, pin_invalido}, p49_registro:nuevo_token(PinMalo)),
    {ok, Token, Expira} = p49_registro:nuevo_token(Pin),
    ?assert(is_binary(Token)),
    ?assert(Expira > p49_util:ahora_seg()),
    ?assert(p49_registro:validar_token(Token)),
    ?assertNot(p49_registro:validar_token(<<"token-inventado">>)),
    ok = p49_registro:revocar_token(Token),
    ?assertNot(p49_registro:validar_token(Token)).

admin_zonas_y_cajones() ->
    %% Al cerrar una zona se liberan las reservas pendientes, pero los
    %% cajones ocupados no se tocan.
    {ok, _} = p49_zona:reservar(<<"Z2">>, <<"Z2-001">>, <<"res-cierre">>,
                                <<"CIE-001">>, <<"E1">>),
    {ok, Cerrada} = ?SERVER:admin_zona_estado(<<"Z2">>, <<"cerrado">>),
    {ok, TrasCierre} = p49_zona:detalle(<<"Z2">>, <<"Z2-001">>),
    ?assertEqual(libre, maps:get(estado, TrasCierre)),
    ?assertEqual(false, maps:get(abierto, Cerrada)),
    ?assertEqual({error, zona_cerrada},
                 p49_zona:reservar(<<"Z2">>, <<"Z2-001">>,
                                   p49_util:id("res"), <<"ABC-123">>,
                                   <<"E1">>)),

    {ok, Mapa} = ?SERVER:mapa(<<"E1">>),
    [ZonaO1] = [Z || Z <- maps:get(zonas, Mapa),
                     maps:get(id, Z) =:= <<"Z2">>],
    ?assertEqual(false, maps:get(abierto, ZonaO1)),
    {ok, Abierta} = ?SERVER:admin_zona_estado(<<"Z2">>, <<"abierto">>),
    ?assertEqual(true, maps:get(abierto, Abierta)),
    ?assertEqual({error, estado_invalido},
                 ?SERVER:admin_zona_estado(<<"Z1">>, <<"talvez">>)),

    CajonId = <<"Z1-374">>,
    ok = ?SERVER:admin_cajon_estado(CajonId, <<"fuera_servicio">>,
                                    <<"Prueba eunit">>),
    {ok, Fuera} = p49_zona:detalle(<<"Z1">>, CajonId),
    ?assertEqual(fuera_servicio, maps:get(estado, Fuera)),
    ResumenFuera = p49_zona:resumen(<<"Z1">>),
    ?assert(maps:get(fuera_servicio, ResumenFuera) >= 1),

    ok = ?SERVER:admin_cajon_estado(CajonId, <<"libre">>, <<>>),
    {ok, Habilitado} = p49_zona:detalle(<<"Z1">>, CajonId),
    ?assertEqual(libre, maps:get(estado, Habilitado)),
    ?assertEqual({error, estado_invalido},
                 ?SERVER:admin_cajon_estado(CajonId, <<"ocupado">>, <<>>)),
    ?assertEqual({error, zona_no_encontrada},
                 ?SERVER:admin_cajon_estado(<<"ZZ-999">>, <<"libre">>, <<>>)),

    %% Un cajon ocupado no puede pasar a mantenimiento.
    OcupadoId = <<"Z3-374">>,
    {ok, PidOcupado} = p49_cajon_sup:pid(<<"Z3">>, 374),
    ok = p49_cajon:ocupar(PidOcupado, <<"OCU-001">>),
    ?assertEqual({error, cajon_ocupado},
                 ?SERVER:admin_cajon_estado(OcupadoId, <<"fuera_servicio">>,
                                            <<>>)),
    %% Tampoco debe poder "habilitarse" un cajon ocupado: eso lo liberaria
    %% sin registrar la salida.
    ?assertEqual({error, cajon_ocupado},
                 ?SERVER:admin_cajon_estado(OcupadoId, <<"libre">>, <<>>)),
    ok = p49_zona:liberar(<<"Z3">>, OcupadoId, <<"Fin de prueba">>),
    {ok, LibreOtraVez} = p49_zona:detalle(<<"Z3">>, OcupadoId),
    ?assertEqual(libre, maps:get(estado, LibreOtraVez)).

admin_placa_y_liberacion() ->
    %% El cajon arranca vacio y solo se ocupa con una entrada real.
    {ok, R} = ?SERVER:recomendar(<<"E6">>, <<"visitante">>, <<"LIB-001">>),
    CajonId = maps:get(id, maps:get(cajon, R)),
    Zona = maps:get(zona, maps:get(cajon, R)),
    ReservaId = maps:get(reserva_id, R),
    {ok, _} = ?SERVER:confirmar(ReservaId, CajonId),
    {ok, _} = ?SERVER:entrada(<<"LIB-001">>, CajonId),

    %% El mapa publico no debe filtrar la placa del ocupante.
    Publicos = p49_zona:cajones(Zona),
    Publico = hd([C || C <- Publicos, maps:get(id, C) =:= CajonId]),
    ?assertNot(maps:is_key(placa, Publico)),

    %% El listado administrativo si la expone junto con la reserva.
    {ok, Admin} = ?SERVER:admin_cajones(Zona),
    AdminCajon = hd([C || C <- maps:get(cajones, Admin),
                          maps:get(id, C) =:= CajonId]),
    ?assertEqual(<<"LIB-001">>, maps:get(placa, AdminCajon)),
    ?assertEqual(ReservaId, maps:get(reserva_id, AdminCajon)),

    %% Liberar desde admin funciona aunque el cajon este ocupado.
    ok = ?SERVER:admin_cajon_liberar(CajonId, <<"Prueba eunit">>),
    {ok, Detalle} = p49_zona:detalle(Zona, CajonId),
    ?assertEqual(libre, maps:get(estado, Detalle)),
    ?assertEqual(undefined, maps:get(reserva, Detalle)),

    %% La placa queda libre para volver a reservar.
    {ok, R2} = ?SERVER:recomendar(<<"E6">>, <<"visitante">>, <<"LIB-001">>),
    {ok, _} = ?SERVER:cancelar(maps:get(reserva_id, R2),
                               maps:get(id, maps:get(cajon, R2))).

%% ------------------------------------------------------------------
%% Expoiracion de una reserva (cajon aislado con TTL corto)
%% ------------------------------------------------------------------

reserva_expira() ->
    application:set_env(?APP, reserva_ttl_seg, 1),
    try
        Cajon = #{id => <<"T-001">>, zona => <<"ZZ">>, numero => 1,
                  tipo => <<"visitante">>},
        {ok, Pid} = p49_cajon:start_link(Cajon),
        unlink(Pid),
        try
            {ok, Reserva} = p49_cajon:reservar(Pid, p49_util:id("res"),
                                               <<"TTL-001">>, <<"E1">>, 1),
            ReservaId = maps:get(id, Reserva),
            ?assertEqual(reservado, maps:get(estado, p49_cajon:estado(Pid))),
            esperar(fun() ->
                            ?assertEqual(libre,
                                         maps:get(estado,
                                                  p49_cajon:estado(Pid)))
                    end),
            %% Confirmar despues de vencer tampoco debe revivir la reserva.
            ?assertEqual({error, reserva_no_encontrada},
                         p49_cajon:confirmar(Pid, ReservaId))
        after
            try gen_statem:stop(Pid)
            catch _:_ -> ok
            end
        end
    after
        application:set_env(?APP, reserva_ttl_seg, 600)
    end.

%% ------------------------------------------------------------------
%% Caos: caidas y recuperacion
%% ------------------------------------------------------------------

caos_zona_y_cajon() ->
    {ok, R} = ?SERVER:recomendar(<<"E1">>, <<"alumno">>, <<"CAO-001">>),
    CajonId = maps:get(id, maps:get(cajon, R)),
    Zona = maps:get(zona, maps:get(cajon, R)),
    ReservaId = maps:get(reserva_id, R),

    ViejaZona = whereis(p49_config:zona_atom(Zona)),
    ?assert(is_pid(ViejaZona)),
    exit(ViejaZona, kill),
    esperar(fun() ->
                    NuevaZona = whereis(p49_config:zona_atom(Zona)),
                    ?assert(is_pid(NuevaZona)),
                    ?assert(NuevaZona =/= ViejaZona),
                    ?assertMatch(#{total := 375},
                                 p49_zona:resumen(Zona))
            end),
    {ok, Recuperada} = p49_zona:detalle(Zona, CajonId),
    ?assertEqual(reservado, maps:get(estado, Recuperada)),
    ?assertEqual(ReservaId, maps:get(id, maps:get(reserva, Recuperada))),
    {ok, _} = ?SERVER:cancelar(ReservaId, CajonId),

    %% Un cajon muerto vuelve libre y la zona corrige el conteo.
    {ok, ViejoCajon} = p49_cajon_sup:pid(<<"Z3">>, 375),
    exit(ViejoCajon, kill),
    esperar(fun() ->
                    {ok, NuevoCajon} = p49_cajon_sup:pid(<<"Z3">>, 375),
                    ?assert(is_pid(NuevoCajon)),
                    ?assert(NuevoCajon =/= ViejoCajon),
                    ?assertEqual(libre,
                                 maps:get(estado,
                                          p49_cajon:estado(NuevoCajon)))
            end),
    {ok, NuevoCajon2} = p49_cajon_sup:pid(<<"Z3">>, 375),
    {ok, DetalleCajon} = p49_zona:detalle(<<"Z3">>, <<"Z3-375">>),
    ?assertEqual(libre, maps:get(estado, DetalleCajon)),
    ?assert(is_pid(maps:get(pid, DetalleCajon))),
    ?assertEqual(NuevoCajon2, maps:get(pid, DetalleCajon)),

    %% Un cajon reservado que muere se restaura con la reserva que la zona
    %% conocia, no se entrega libre a otra placa.
    {ok, RReservado} = ?SERVER:recomendar(<<"E2">>, <<"alumno">>,
                                          <<"CAO-002">>),
    CajonReservado = maps:get(id, maps:get(cajon, RReservado)),
    ZonaReservada = maps:get(zona, maps:get(cajon, RReservado)),
    ReservaReservada = maps:get(reserva_id, RReservado),
    NumeroReservado = p49_config:numero_de_cajon(CajonReservado),
    {ok, ViejoReservado} = p49_cajon_sup:pid(ZonaReservada, NumeroReservado),
    exit(ViejoReservado, kill),
    esperar(fun() ->
                    {ok, NuevoReservado} =
                        p49_cajon_sup:pid(ZonaReservada, NumeroReservado),
                    ?assert(NuevoReservado =/= ViejoReservado),
                    {ok, DetalleReservado} =
                        p49_zona:detalle(ZonaReservada, CajonReservado),
                    ?assertEqual(reservado,
                                 maps:get(estado, DetalleReservado)),
                    ?assertEqual(ReservaReservada,
                                 maps:get(id,
                                          maps:get(reserva, DetalleReservado)))
            end),
    {ok, _} = ?SERVER:cancelar(ReservaReservada, CajonReservado).

caos_coordinador() ->
    Viejo = whereis(?SERVER),
    ?assert(is_pid(Viejo)),
    exit(Viejo, kill),
    esperar(fun() ->
                    Nuevo = whereis(?SERVER),
                    ?assert(is_pid(Nuevo)),
                    ?assert(Nuevo =/= Viejo),
                    ?assertEqual(pong, ?SERVER:ping())
            end),
    Catalogo = ?SERVER:catalogo(),
    ?assertEqual(1500, maps:get(total, maps:get(resumen, Catalogo))),
    ?assertEqual(4, maps:get(zonas_abiertas, maps:get(resumen, Catalogo))).

%% ------------------------------------------------------------------
%% Simulacion concurrente
%% ------------------------------------------------------------------

simulacion_concurrente() ->
    {ok, Resultado} = p49_simulacion:concurrente(
                        #{<<"solicitudes">> => 40,
                          <<"edificio">> => <<"E2">>,
                          <<"tipo_usuario">> => <<"alumno">>}),
    ?assertEqual(40, maps:get(solicitudes, Resultado)),
    ?assertEqual(40, maps:get(asignadas, Resultado)),
    ?assertEqual(0, maps:get(rechazadas, Resultado)),
    ?assertEqual(0, maps:get(duplicados, Resultado)),
    ?assertEqual(40, maps:get(unicos, Resultado)),
    ?assert(maps:get(tiempo_ms, Resultado) >= 0),
    ?assertEqual(40, lists:sum(maps:values(maps:get(por_zona, Resultado)))),
    Resumen = p49_zona:resumen(<<"Z1">>),
    ?assertEqual(375, maps:get(total, Resumen)).

%% ------------------------------------------------------------------
%% Soporte
%% ------------------------------------------------------------------

esperar(Fun) ->
    esperar(Fun, 100).

esperar(Fun, 0) ->
    Fun();
esperar(Fun, Intentos) ->
    try Fun()
    catch
        _:_ ->
            timer:sleep(50),
            esperar(Fun, Intentos - 1)
    end.
