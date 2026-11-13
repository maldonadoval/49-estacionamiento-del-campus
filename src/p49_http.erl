-module(p49_http).
-compile(nowarn_deprecated_catch).
-behaviour(gen_server).

-export([start_link/0, rutas/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    case p49_config:http_enabled() of
        false ->
            {ok, #{listener => undefined}};
        true ->
            App = p49_config:app(),
            Dispatch = cowboy_router:compile([{'_', rutas()}]),
            Port = p49_config:http_port(),
            %% Si este gen_server se reinicia por un fallo, el listener de
            %% cowboy de la instancia anterior sigue vivo. Se detiene antes
            %% de volver a registrarlo para que el reinicio sea idempotente.
            catch cowboy:stop_listener(p49_http_listener),
            {ok, _Pid} = cowboy:start_clear(
                           p49_http_listener,
                           [{port, Port}, {ip, {0, 0, 0, 0}}],
                           #{env => #{dispatch => Dispatch}}),
            logger:info("interfaz web escuchando en http://localhost:~p", [Port],
                        #{modulo => ?MODULE}),
            {ok, #{listener => p49_http_listener, port => Port, app => App}}
    end.

rutas() ->
    App = p49_config:app(),
    [
     {"/", cowboy_static, {priv_file, App, "www/index.html"}},
     {"/static/[...]", cowboy_static, {priv_dir, App, "www"}},
     {"/api/catalogo", p49_http_handler, catalogo},
     {"/api/mapa", p49_http_handler, mapa},
     {"/api/recomendaciones", p49_http_handler, recomendaciones},
     {"/api/recomendaciones/:id/alternativa", p49_http_handler, alternativa},
     {"/api/recomendaciones/:id/confirmar", p49_http_handler, confirmar},
     {"/api/recomendaciones/:id/cancelar", p49_http_handler, cancelar},
     {"/api/estacionamientos/entrada", p49_http_handler,
      estacionamiento_entrada},
     {"/api/estacionamientos/salida", p49_http_handler,
      estacionamiento_salida},
     {"/api/estacionamientos/:placa", p49_http_handler, estacionamiento_placa},
     {"/api/admin/sesion", p49_http_handler, admin_sesion},
     {"/api/admin/estado", p49_http_handler, admin_estado},
     {"/api/admin/zonas/:id", p49_http_handler, admin_zona},
     {"/api/admin/cajones", p49_http_handler, admin_cajones},
     {"/api/admin/cajones/:id", p49_http_handler, admin_cajon},
     {"/api/admin/movimientos", p49_http_handler, admin_movimientos},
     {"/api/admin/incidencias", p49_http_handler, admin_incidencias},
     {"/api/admin/simulacion", p49_http_handler, admin_simulacion},
     {"/api/admin/escenario", p49_http_handler, admin_escenario},
     {"/api/admin/diagnostico", p49_http_handler, admin_diagnostico},
     {"/metrics", p49_http_handler, metricas},
     {"/ws/mapa", p49_ws_handler, []},
     {"/favicon.ico", p49_http_handler, favicon},
     {"/[...]", p49_http_handler, no_encontrado}
    ].

handle_call(_Msg, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, #{listener := undefined}) ->
    ok;
terminate(_Reason, #{listener := Listener}) ->
    catch cowboy:stop_listener(Listener),
    ok.
