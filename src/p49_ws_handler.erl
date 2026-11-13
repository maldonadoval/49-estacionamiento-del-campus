-module(p49_ws_handler).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2,
         terminate/3]).

init(Req, _Opts) ->
    {cowboy_websocket, Req, #{edificio => <<"E1">>}}.

websocket_init(State) ->
    erlang:send_after(5000, self(), tick),
    {reply, mensaje_mapa(State), State}.

websocket_handle({text, <<"ping">>}, State) ->
    {reply, {text, <<"pong">>}, State};
websocket_handle({text, Texto}, State) ->
    case p49_json:decode(Texto) of
        {ok, #{<<"accion">> := <<"suscribir">>,
               <<"edificio">> := Edificio}} ->
            Nuevo = State#{edificio := Edificio},
            {reply, mensaje_mapa(Nuevo), Nuevo};
        _ ->
            {ok, State}
    end;
websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info(tick, State) ->
    erlang:send_after(5000, self(), tick),
    {reply, mensaje_mapa(State), State};
websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, _State) ->
    ok.

mensaje_mapa(#{edificio := Edificio}) ->
    Termino = case p49_estacionamiento_del_campus_server:mapa(Edificio) of
                  {ok, Mapa} ->
                      #{tipo => <<"mapa">>, edificio => Edificio,
                        datos => Mapa, ts => p49_util:ahora_seg()};
                  {error, Motivo} ->
                      #{tipo => <<"error">>, error => Motivo,
                        ts => p49_util:ahora_seg()}
              end,
    {text, p49_json:encode(Termino)}.
