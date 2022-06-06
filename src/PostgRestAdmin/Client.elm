module PostgRestAdmin.Client exposing
    ( Client
    , toHostUrl
    , Table
    , getTable
    , tableName
    , fetchRecord
    , fetchRecordList
    , saveRecord
    , deleteRecord
    , task
    , fetch
    , Error
    , errorToString
    , isAuthenticated
    , toJwtString
    )

{-|


# Client

@docs Client
@docs toHostUrl


# Table

@docs Table
@docs getTable
@docs tableName


# Requests

Note that the request functions **do not produce a vanilla Elm
[Cmd](https://package.elm-lang.org/packages/elm/core/latest/Platform-Cmd#Cmd)**
but a [PostgRestAdmin.Cmd](PostgRestAdmin.Cmd).

@docs fetchRecord
@docs fetchRecordList
@docs saveRecord
@docs deleteRecord
@docs task
@docs fetch

@docs Error
@docs errorToString


# Authentication

@docs isAuthenticated
@docs toJwtString

-}

import Dict
import Dict.Extra as Dict
import Http exposing (header)
import Internal.Client as Client exposing (Client)
import Internal.Cmd as Internal
import Internal.Field as Field
import Internal.Schema as Schema exposing (Column, Constraint(..), Table)
import Json.Decode as Decode exposing (Decoder, Value)
import Json.Encode as Encode
import PostgRestAdmin.Cmd as AppCmd
import PostgRestAdmin.Record as Record exposing (Record)
import Postgrest.Client as PG exposing (Selectable)
import Task exposing (Task)
import Url exposing (Url)
import Utils.Task as Internal
    exposing
        ( Error(..)
        , handleJsonValue
        , handleResponse
        )


{-| Represents a client for a PostgREST instance, including authentication
params.

See [Config](PostgRestAdmin.Config) and
[Config.FormAuth](PostgRestAdmin.Config.FormAuth) for authentication
configuration options.

-}
type alias Client =
    Client.Client


{-| Represents a PostgREST table.
-}
type alias Table =
    Schema.Table


{-| Request error.
-}
type alias Error =
    Internal.Error


{-| Obtain the PostgREST instance url.
-}
toHostUrl : Client -> Url
toHostUrl =
    Client.toHostUrl


{-| Does the client has a valid JWT?
-}
isAuthenticated : Client -> Bool
isAuthenticated =
    Client.isAuthenticated


{-| Obtain the JWT as a string.
-}
toJwtString : Client -> Maybe String
toJwtString client =
    Client.toJwtString client


{-| Obtain a table from the table name.
-}
getTable : String -> Client -> Maybe Table
getTable =
    Client.getTable


{-| Obtain the name of a table
-}
tableName : Table -> String
tableName table =
    table.name


{-| Transform [Error](#Error) to an error explanation.
-}
errorToString : Error -> String
errorToString =
    Internal.errorToString



-- VIEW


{-| Fetches a record for a given table.
`expect` param requires a function that returns a `Msg`.

    import PostgRestAdmin.Cmd as AppCmd

    fetchOne : (Result Error Record -> msg) -> String -> Client -> AppCmd.Cmd Msg
    fetchOne tagger tableName client =
        case getTable tableName client of
            Just table ->
                fetchRecord
                    { client = client
                    , table = table
                    , params = []
                    , expect = tagger
                    }

            Nothing ->
                AppCmd.none

-}
fetchRecord :
    { client : Client
    , table : Table
    , id : String
    , expect : Result Error Record -> msg
    }
    -> AppCmd.Cmd msg
fetchRecord { client, table, expect, id } =
    let
        mapper =
            mapResult expect (Record.decoder table)
    in
    case tablePrimaryKeyName table of
        Just primaryKeyName ->
            let
                queryString =
                    PG.toQueryString
                        [ PG.select (selects table)
                        , PG.eq (PG.string id) |> PG.param primaryKeyName
                        , PG.limit 1
                        ]
            in
            fetch mapper <|
                task
                    { client = client
                    , method = "GET"
                    , headers =
                        [ header "Accept" "application/vnd.pgrst.object+json" ]
                    , path = "/" ++ tableName table ++ "?" ++ queryString
                    , body = Http.emptyBody
                    , timeout = Nothing
                    }

        Nothing ->
            fetch mapper missingPrimaryKey


{-| Fetches a list of records for a given table.
`expect` param requires a function that returns a `Msg`.

    import PostgRestAdmin.Cmd as AppCmd

    fetchList : (Result Error (List Record) -> Msg) -> String -> Client -> AppCmd.Cmd Msg
    fetchList tagger tableName client =
        case getTable tableName client of
            Just table ->
                fetchRecordList
                    { client = client
                    , table = table
                    , params = []
                    , expect = tagger
                    }

            Nothing ->
                AppCmd.none

-}
fetchRecordList :
    { client : Client
    , table : Table
    , params : PG.Params
    , expect : Result Error (List Record) -> msg
    }
    -> AppCmd.Cmd msg
fetchRecordList { client, table, params, expect } =
    let
        queryString =
            PG.toQueryString
                (PG.select (selects table) :: params)
    in
    fetch (mapResult expect (Decode.list (Record.decoder table))) <|
        task
            { client = client
            , method = "GET"
            , headers = []
            , path = "/" ++ tableName table ++ "?" ++ queryString
            , body = Http.emptyBody
            , timeout = Nothing
            }


{-| Saves a record.
`expect` param requires a function that returns a `Msg`.

You can use [expectRecord](#expectRecord) to interpret the result as a
[Record](PostgRestAdmin.Record).

    import PostgRestAdmin.Cmd as AppCmd

    save : (Result Error () -> Msg) -> Record -> Maybe String -> Client -> AppCmd.Cmd Msg
    save tagger record id client =
        saveRecord
            { client = client
            , record = record
            , id = id
            , expect = tagger
            }

-}
saveRecord :
    { client : Client
    , record : Record
    , id : Maybe String
    , expect : Result Error () -> msg
    }
    -> AppCmd.Cmd msg
saveRecord { client, record, id, expect } =
    let
        queryString =
            PG.toQueryString
                [ PG.select (selects record.table)
                , PG.limit 1
                ]

        path =
            Record.location record
                |> Maybe.map (\p -> p ++ "&" ++ queryString)
                |> Maybe.withDefault
                    ("/" ++ Record.tableName record ++ "?" ++ queryString)

        mapper =
            mapResult expect (Decode.succeed ())

        params =
            { client = client
            , method = "PATCH"
            , headers = []
            , path = path
            , body = Http.jsonBody (Record.encode record)
            , timeout = Nothing
            }
    in
    case id of
        Just _ ->
            fetch mapper (task params)

        Nothing ->
            fetch mapper (task { params | method = "POST" })


{-| Deletes a record.
`expect` param requires a function that returns a `Msg`.

    import PostgRestAdmin.Cmd as AppCmd

    delete : (Result Error Record -> Msg) -> Record -> Client -> AppCmd.Cmd Msg
    delete tagger record client =
        deleteRecord
            { client = client
            , record = record
            , expect = tagger
            }

-}
deleteRecord :
    { record : Record
    , expect : Result Error () -> msg
    }
    -> Client
    -> AppCmd.Cmd msg
deleteRecord { record, expect } client =
    let
        mapper =
            mapResult expect (Decode.succeed ())
    in
    case Record.location record of
        Just path ->
            fetch mapper <|
                task
                    { client = client
                    , method = "DELETE"
                    , headers = []
                    , path = path
                    , body = Http.emptyBody
                    , timeout = Nothing
                    }

        Nothing ->
            fetch mapper missingPrimaryKey


{-| Task to perform a request to a PostgREST instance resource.

The path can identify a plural resource such as `/posts` in which case an
[upsert](https://postgrest.org/en/stable/api.html?highlight=upsert#upsert)
operation will be performed, or a singular resource such as '/posts?id=eq.1'.

-}
task :
    { client : Client
    , method : String
    , headers : List Http.Header
    , path : String
    , body : Http.Body
    , timeout : Maybe Float
    }
    -> Task Error Value
task { client, method, headers, path, body, timeout } =
    Client.task
        { client = client
        , method = method
        , headers = headers
        , path = path
        , body = body
        , resolver = Http.stringResolver handleJsonValue
        , timeout = timeout
        }


{-| Perform a task converting the result to a message.
-}
fetch : (Result Error Value -> msg) -> Task Error Value -> Internal.Cmd msg
fetch =
    Internal.Fetch



-- UTILS


missingPrimaryKey : Task Error a
missingPrimaryKey =
    Task.fail (Internal.RequestError "I cound't figure the primary key")


selects : Table -> List Selectable
selects table =
    Dict.values table.columns
        |> List.filterMap associationJoin
        |> (++) (Dict.keys table.columns |> List.map PG.attribute)


associationJoin : Column -> Maybe Selectable
associationJoin { constraint } =
    case constraint of
        ForeignKey foreignKey ->
            foreignKey.labelColumnName
                |> Maybe.map
                    (\n ->
                        PG.resource foreignKey.tableName
                            (PG.attributes [ n, "id" ])
                    )

        _ ->
            Nothing


tablePrimaryKeyName : Table -> Maybe String
tablePrimaryKeyName table =
    Dict.find (\_ column -> Field.isPrimaryKey column) table.columns
        |> Maybe.map Tuple.first


mapResult : (Result Error a -> msg) -> Decoder a -> Result Error Value -> msg
mapResult expect decoder result =
    result
        |> Result.andThen
            (Decode.decodeValue decoder >> Result.mapError DecodeError)
        |> expect
