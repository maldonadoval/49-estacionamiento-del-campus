-module(p49_cajon_sup).
-behaviour(supervisor).

-export([start_link/1, init/1, nombre/1, lista/1, pid/2]).

start_link(ZonaId) ->
    supervisor:start_link({local, nombre(ZonaId)}, ?MODULE, [ZonaId]).

nombre(ZonaId) ->
    binary_to_atom(<<"p49_cajones_", ZonaId/binary>>, utf8).

%% Devuelve [{Numero, Pid}] de los cajones vivos de una zona.
lista(ZonaId) ->
    Hijos = supervisor:which_children(nombre(ZonaId)),
    [{Numero, Pid} || {Numero, Pid, worker, _} <- Hijos, is_pid(Pid)].

pid(ZonaId, Numero) ->
    case lists:keyfind(Numero, 1, lista(ZonaId)) of
        {Numero, Pid} -> {ok, Pid};
        false -> {error, cajon_no_disponible}
    end.

init([ZonaId]) ->
    Hijos = [#{id => maps:get(numero, Cajon),
               start => {p49_cajon, start_link, [Cajon]},
               restart => permanent,
               shutdown => 2000,
               type => worker}
             || Cajon <- p49_config:cajones_zona(ZonaId)],
    {ok, {#{strategy => one_for_one, intensity => 500, period => 60}, Hijos}}.
