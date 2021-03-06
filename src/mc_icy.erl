%%% -------------------------------------------------------------------
%% Copyright 2011 Ulf Angermann, Martin Huber
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% 
%%     http://www.apache.org/licenses/LICENSE-2.0
%% 
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.


%%% -------------------------------------------------------------------
%%% Author  : Martin Huber / martin.huber@innoq.com
%%% Description :
%%%
%%% Created : 
%%% -------------------------------------------------------------------


-module(mc_icy). 
-behaviour(gen_server).

%% API
-export([
         start_link/4,
		 start_link/3,
         start_link/2,
         stop/0
         ]).   

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-include_lib("eunit/include/eunit.hrl").
-include_lib("../include/mc.hrl").

-define(SERVER, ?MODULE).
-define(STRTITLECONST, "StreamTitle='").
-define(STRURLCONST, "';Stre").
-define(DEFAULT_PORT, 80).
-define(DEFAULT_FILE, "/tmp/").
-define(METAINTDEFAULT, 8192).
-define(METADATA_DEF, " HTTP/1.0\r\nIcy-Metadata: 1\r\n\r\n").

-record(state, {	rstation, 
					sofar, 
					filepath, 
					lsock, 
					gotheader=false, 
					metaint=0, 
					interpret, 
					title, 
					metaoverlap=0,
					metabeforeoverlap}).

%%%===================================================================
%%% API
%%%===================================================================
%%--------------------------------------------------------------------
%% @doc Starts the server.
%%
%% @spec start_link(Port::integer()) -> {ok, Pid}
%% where
%%  Pid = pid()
%% @end
%%--------------------------------------------------------------------
start_link(Rstation, File) ->
	gen_server:start_link({local, Rstation#rstation.name}, ?MODULE, [Rstation, File], []).

start_link(Port, Host, Location, File) ->
	Rstation = #rstation{streamport=Port, streamhost=Host, streamlocation=Location, name=xyz},
    gen_server:start_link({local, Rstation#rstation.name}, ?MODULE, [Rstation, File], []).

start_link(Host, Location, File) ->
	Rstation = #rstation{streamport=?DEFAULT_PORT, streamhost=Host, streamlocation=Location},
    gen_server:start_link({local, Rstation#rstation.name}, ?MODULE, [Rstation,  File], []).


%%--------------------------------------------------------------------
%% @doc Stops the server.
%% @spec stop() -> ok
%% @end
%%--------------------------------------------------------------------
stop() ->
    gen_server:cast(?SERVER, stop).
                                        
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Rstation, FilePath]) -> 
	io:format("Start Listening to: ~p~n", [Rstation]),
	GetStr = string:concat("GET ", string:concat(Rstation#rstation.streamlocation, ?METADATA_DEF))	,
	{ok, Socket} = gen_tcp:connect(Rstation#rstation.streamhost, Rstation#rstation.streamport, [binary, {packet, 0}]),
	ok = gen_tcp:send(Socket, GetStr),
	MetaInit = <<>>,
    {ok, #state{rstation = Rstation, sofar=[], lsock = Socket, filepath=FilePath, metabeforeoverlap=MetaInit}}.

handle_call(_,_,State) ->
	{reply, {ok, State}}.

handle_cast(stop, State) ->
    {stop, normal, State}.

handle_info({tcp, _Socket, Bin}, State) ->
	%% First we need to check for the initial http-Headers of the Shoutcast-Stream
	case State#state.gotheader of
		%% true is the standard case, where we already have already analyzed the http-Headers
		true ->
			{NewBin, Metadata, MetaOverlap} = extract(Bin, State),
			case MetaOverlap =:= 0 of
				true -> 
						Md = list_to_binary([State#state.metabeforeoverlap,Metadata]),
						{Change, NewInterpret, NewTitle} = evaluateStreamtitle(Md, State#state.interpret, State#state.title),
						MetaSave = <<>>;
				false ->
						Change = false,
						NewInterpret = State#state.interpret,
						NewTitle = State#state.title,
						MetaSave = Metadata
			end,
			%% Change marks a new piece of music, 
			%% so let's put out the old to file or whereever and record the new one
			case Change of 
				true -> 
						% This is a bit complicated, when we want to write a file we: 
						% 1st have to add the most recent bin message
						StateNew = State#state{sofar = [NewBin|State#state.sofar]},
						% 2nd: Calculate how much bytes we need to leave to the next round (to keep correct position) 
						TotSize = getsizeofbininlist(StateNew#state.sofar),   
						RestSize = (TotSize rem StateNew#state.metaint) + StateNew#state.metaint,		  
						% 3rd Then split restsize-part of the whole binary for next file
						Num = TotSize-RestSize, 
						 <<_:Num/binary,RestBin/binary>> = list_to_binary(lists:reverse(StateNew#state.sofar)),
						% 4th write file with what we have
						finishFile(StateNew),
						% Last: Return new state with restbin
						{noreply, State#state{sofar = [RestBin], interpret=NewInterpret, 
											  title=NewTitle, metaoverlap=MetaOverlap, metabeforeoverlap=MetaSave}};
				false -> 
						{noreply, State#state{sofar = [NewBin|State#state.sofar], interpret=NewInterpret, 
											  title=NewTitle, metaoverlap=MetaOverlap, metabeforeoverlap=MetaSave}}
			end;

		%% false: we need to analyze/expect http-Headers first (one time init)
		false -> 
			case analyzeHeaders(Bin) of 
 				{ok, MetaInt, BinRight} -> 	
									{noreply, State#state{gotheader=true, metaint=MetaInt, sofar=[BinRight]}};
				{notfound, BinRight}	->	{noreply, State#state{gotheader=false, sofar=[BinRight]}}
			end
	end;

handle_info({tcp_closed, _Socket}, State) ->
	io:format("hi:~p~n", [tcp_closed]),
	stop(),
	{noreply, State};

handle_info(timeout, State) ->
	io:format("hi:~p~n", [timeout]),
	stop(),
    {noreply, State}.

terminate(_Reason, State) -> 
	finish(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.      


%%%===================================================================
%%% Internal Functions
%%%===================================================================
%%-------------------------------------------------------------------------------------
%% @doc extract method
%% @end
%%-------------------------------------------------------------------------------------
extract(Bin, State) -> 
	New = size(Bin),
	SoFarSize = getsizeofbininlist(State#state.sofar),
	case SoFarSize =:= 0 of
		true ->  
				FrameFillSize =  0;  							
		false -> 
				FrameFillSize = SoFarSize rem State#state.metaint

	end,

	RestSize =  State#state.metaint - FrameFillSize,

	% FrameFillSize = Size of Data filling the most recent frame
	% Y = Room for data until the next metadata comes
	% Overlp is a possible overlap of metadata from last package to this one
	Ovrlp = State#state.metaoverlap,
	
%% 	io:format("SoFarSize:~p / FrameFillSize:~p / RestSize:~p / Overlap: ~p~n", [SoFarSize, FrameFillSize, RestSize, Ovrlp]),
	if 
		Ovrlp =:= 0, RestSize > 0 -> % When there's no overlap and room for data -> handle data
			handleData(Bin, New, RestSize);
		Ovrlp > 0 -> 		  % When there IS a overlap, handle meta with that overlap
			handleMeta(Bin, Ovrlp);
		true ->				 % so there's no overlap but also no room for data - then we handle meta normally
			handleMeta(Bin)
	end.



%%-------------------------------------------------------------------------------------
%% @doc
%% @end
%%-------------------------------------------------------------------------------------
handleData(Bin, New, RestSize) 
  	-> 
		if 
			New < RestSize ->  		% remember RestSize? If there's more/exact room for data then we give back just data
					{Bin, <<>>, 0};    
			New =:= RestSize -> 	% this is a perfect fit, but we should start with a overlap signaling the Shoutcast length byte (-1)
 					{Bin, <<>>, -1};	
			New > RestSize 	-> 		% so we have a bit metadata in there! Split it and give the meta to handlemeta
				 <<BinTemp:RestSize/binary,MetaDataTemp/binary>> = Bin, 
				{BinNew, MetaData, MetaOverlap} = handleMeta(MetaDataTemp),
				{<<BinTemp/binary,BinNew/binary>>, MetaData, MetaOverlap}
		end.


				
%%-------------------------------------------------------------------------------------
%% @doc handle meta with no overlap. takes the first byte, and calculates that by 16 bytes, <br>
%%		the data until up to that point is meta. the rest is data and both will be given back.
%% @end
%%-------------------------------------------------------------------------------------	
handleMeta(Bin) 
  ->
	<<Byte:1/binary,Rest/binary>> = Bin,
	SizeOfMeta = binary:decode_unsigned(Byte) * 16,
	RestSize = size(Rest),
%%   	io:format("---~nMetaSize:~p - RestSize:~p BinSize:~p~n", [SizeOfMeta, RestSize, size(	Bin)]),	
	if 	
		SizeOfMeta =:= 0 
		  		-> {Rest, <<>>, 0};			
		RestSize > SizeOfMeta 
		  		-> 
					<<Meta:SizeOfMeta/binary,Data/binary>> = Rest,
				   {Data, Meta, 0};		% 0 at end means no overlap of metadata
		RestSize =:= SizeOfMeta ->
		  		   {<<>>, Rest, 0};	   % 0 at end means no overlap of metadata, all is Meta
		RestSize < SizeOfMeta ->
					{<<>>, Rest, SizeOfMeta - RestSize}  %% Calc. Value at end means is overlap of metadata, all is Meta   
	end.

			

%%-------------------------------------------------------------------------------------
%% @doc metadata with overlap is simpler, we just take the overlap, and split
%% binaries until that point. first part is meta, rest is data (music, yeah)
%% @end
%%-------------------------------------------------------------------------------------	
handleMeta(Bin, Ovrlp) 
  ->
	case Ovrlp =:= -1 of
					%% -1 is a signal for overlap starts with length byte, do a normal metahandling then
		true -> 	
					handleMeta(Bin);
		false ->	
					io:format("Alarm: Overlap of~p recognized - binsize is: ~p...~n", [Ovrlp, size(Bin)]),
					<<Meta:Ovrlp/binary,Data/binary>> = Bin,
 					io:format("handle Meta with Overlap: ~p~n", [{size(Meta), size(Data)}]),
					{Data, Meta, 0}
	end.

%%--------------------------------------------------------------------
%% @doc Finishing a File: Take Title-Information, open file.  
%% write it and close the file again.
%% @end
%%--------------------------------------------------------------------
finishFile(State) ->
	Onwishlist = try
		mc_config:on_wishlist(State#state.interpret, State#state.title)
	catch 
		_:_ -> io:format("WARNING: config-server is not started...~n"), 
			   false
	end,
	
	io:format("OnWishlist = ~p: Station: ~p - ~p-~p~n",[Onwishlist, State#state.rstation#rstation.name, State#state.interpret, State#state.title]),
	if 
		(State#state.interpret /= undefined) and Onwishlist -> 
			FileName = string:concat(State#state.filepath, string:concat(State#state.interpret, string:concat("-", string:concat(
																											 			State#state.title, ".mp3")))),
			io:format("Writing File: ~p~n", [FileName]),
			{ok, FileP} = file:open(FileName, [raw, write, binary]),
    		file:write(FileP, list_to_binary(lists:reverse(State#state.sofar))),
			file:close(FileP),
			{ok};
		true -> 
%% 			garbage_collect(), 
			{ok, nothingsdone} 
	end.


%%--------------------------------------------------------------------
%% @doc Finishing operations. Closing tcp connection  
%%
%% @end
%%--------------------------------------------------------------------
finish(State) ->
	gen_tcp:close(State#state.lsock).


%%--------------------------------------------------------------------
%% @doc Analyze every header for some specific value and returning 
%% 					
%%
%% @end
%%--------------------------------------------------------------------
analyzeHeaders(Bin) ->
	LoEol = string:rstr(binary_to_list(Bin), "\r\n")+1,
	<<BinLeft:LoEol/binary,BinRight/binary>> = Bin,
	ListOfHeaders = string:tokens(binary_to_list(BinLeft), "\r\n"),

%% 	io:format("Headers:~n
%% 		Loh~p~nLoEol~p~nBL~p~nBR~p~n~n", [ListOfHeaders, LoEol, BinLeft, BinRight]),
	case analyzeOfO(ListOfHeaders) of 
		{ok, Value} -> {ok, Value, BinRight};
		{notfound} ->  {notfound, BinRight}
	end.

%%-------------------------------------------------------------------------------------
%% @doc calculates the size of all binary in our memory
%% @end
%%-------------------------------------------------------------------------------------
getsizeofbininlist(L) -> lists:sum([size(I)||I<-L]).



%%-------------------------------------------------------------------------------------
%% @doc Analyze One for one header of header-line-list for the "icy-metaint: " - value 
%% @end
%%------------------------------------------------------------------------------------

analyzeOfO([]) 		
		-> {notfound};
analyzeOfO([H|T]) 	
  		-> case (string:str(H, "icy-metaint:") > 0) of
			   true -> 
			   			Mis = string:strip(string:substr(H, 1+string:str(H, ":"))),
						{MetaInt, _} = string:to_integer(Mis),
						{ok, MetaInt};
			   false-> analyzeOfO(T) 
			end.

%%-------------------------------------------------------------------------------------
%% @doc Evaluates the Stream-Title. It cuts out the information from Metadata,
%% (well, only if there is metadata) between StreamTitle=' and ';StreamUrl.
%% We have only a "Changed"-State, when the old-Interpret is defined, else
%% we like to assume, that this is the first piece of meta at all, and then it's not
%% changed by our definition.
%% @end
%%------------------------------------------------------------------------------------
evaluateStreamtitle (Meta, InterpretOld, TitleOld) -> 
	case size(Meta) > 14 of
		true ->
%% 				io:format("Stream_meta: ~s~n", [Meta]),
				Str = binary_to_list(Meta),
				IndexOfStreamTitleEnd = string:str(Str, ?STRTITLECONST) + length(?STRTITLECONST),
				StrTit = string:substr(Str, IndexOfStreamTitleEnd, string:str(Str, ?STRURLCONST)-IndexOfStreamTitleEnd), 
				Index = string:str(StrTit, " - "),
				Int = string:strip(string:substr(StrTit, 1, Index)),
				T = string:strip(string:substr(StrTit, Index + 2)), 
				Changed = (InterpretOld /= undefined) xor string:equal(Int, InterpretOld) and string:equal(T, TitleOld),
				%io:format("~nInterpret:~p  Title:~p and Changed is:~p~n ", [Int, T, Changed]),
				{Changed, Int,T};	
		false -> 
				{false, InterpretOld, TitleOld}
	end.
		


%%------------------------------------------------------------------------------------
%%------ Test-Functions --------------------------------------------------------------
%%------------------------------------------------------------------------------------


evaluateStreamtitle_test() ->
	evaluateStreamtitle(list_to_binary("StreamTitle='Mandrillus Sphynx - Zanya';Stre"), "", ""),
	evaluateStreamtitle(list_to_binary("StreamTitle='Mandrillus Sphynx - Zanya';StreamURL=http://somafm.com/groovesalad"), "", ""),
	evaluateStreamtitle(list_to_binary("StreamTitle='Schiller - Blind (with Anggun) [Atemlos: Deluxe Edition]';Stre"), "", ""),
%%  	evaluateStreamtitle(list_to_binary("rl='http://www.181.fm';^@^@^@^@^@^@^@^@^@^@^@^@^@^@^@^@"), "", ""),
	ok.


%% "Morcheeba - The Sea';StreamU", "rl='http://www.181.fm';^@^@^@^@^@^@^@^@^@^@^@^@^@^@^@^@"
%% "StreamTitle='Mandrillus Sphynx - Zanya';Stre"

normal_test() ->
	MetaInit = <<>>,
	State = #state{gotheader=true, metaint=40, sofar=[], metabeforeoverlap=MetaInit},
	Data = <<1,2,3,4,5,6,7,8,9,10,1,2,3,4,5,6,7,8,9,10,1,2,3,4,5,6,7,8,9,10,1,2,3,4,5,6,7,8,9,10>>,
	M1 = list_to_binary("StreamTitle='Morcheeba - The Sea';StreamUrl='http://www.181.fm';^@^@^@^@^@^@^@^@^@^@^@^@^@^@^@^@"),
	L3 = trunc((size(M1))/16),
	M3 = list_to_binary([Data, <<L3/integer>>, M1]),
	{noreply, State2} = handle_info({tcp, 1, M3}, State),
	io:format("1st: ~p~n", [State2]),
	{noreply, State3} = handle_info({tcp, 1, Data}, State2),
	io:format("2nd: ~p~n", [State3]),
	true = string:equal(State3#state.interpret, "Morcheeba"),
	true = string:equal(State3#state.title, "The Sea").

	
ovrl_test () ->
	MetaInit = <<>>,
	State = #state{gotheader=true, metaint=20, sofar=[], metabeforeoverlap=MetaInit},
	Data = <<1,2,3,4,5,6,7,8,9,10,1,2,3,4,5,6,7,8,9,10>>,
	M1 = list_to_binary("StreamTitle='Morcheeba - The Sea';StreamU"),
	M2 = list_to_binary([list_to_binary("rl='http://www.181.fm';^@^@^@^@^@^@^@^@^@^@^@^@^@^@^@^@"), Data]),
	L3 = trunc((size(M1) + size(M2))/16),
	M3 = list_to_binary([Data, <<L3/integer>>, M1]),
	{noreply, State2} = handle_info({tcp, 1, M3}, State),
	io:format("1st: ~p~n", [State2]),
	{noreply, State3} = handle_info({tcp, 1, M2}, State2),
	io:format("2nd: ~p~n", [State3]),
	true = string:equal(State3#state.interpret, "Morcheeba"),
	true = string:equal(State3#state.title, "The Sea").
