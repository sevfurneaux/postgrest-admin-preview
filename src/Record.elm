module Record exposing (Record, decoder, primaryKey)

import Basics.Extra exposing (curry, flip)
import Dict exposing (Dict)
import Json.Decode as Decode
    exposing
        ( Decoder
        , bool
        , decodeValue
        , float
        , int
        , maybe
        , string
        )
import Postgrest.Client as PG
import PrimaryKey exposing (PrimaryKey)
import Schema exposing (Definition)
import Value exposing (Column, Value(..))


type alias Record =
    Dict String Value


decoder : List String -> Definition -> Decoder Record
decoder identifiers definition =
    definition
        |> Dict.foldl (decoderFold identifiers definition)
            (Decode.succeed Dict.empty)


decoderFold :
    List String
    -> Definition
    -> String
    -> a
    -> Decoder Record
    -> Decoder Record
decoderFold identifiers definition name _ prevDec =
    let
        insert =
            flip (Dict.insert name)

        map cons dict dec =
            Decode.field name dec |> Decode.map (insert dict << cons)

        foldFun dict =
            case Dict.get name definition |> Maybe.map .value of
                Just (PFloat _) ->
                    maybe float |> map PFloat dict

                Just (PInt _) ->
                    maybe int |> map PInt dict

                Just (PString _) ->
                    maybe string |> map PString dict

                Just (PBool _) ->
                    maybe bool |> map PBool dict

                Just (PPrimaryKey _) ->
                    maybe PrimaryKey.decoder
                        |> map PPrimaryKey dict

                Just (PForeignKey ( table, col ) _ _) ->
                    let
                        mapFun d pk =
                            insert dict <| PForeignKey ( table, col ) d pk

                        refDec i =
                            maybe <| Decode.at [ table, i ] string
                    in
                    Decode.map2 mapFun
                        (Decode.oneOf <| List.map refDec identifiers)
                        (maybe <| Decode.field name PrimaryKey.decoder)

                _ ->
                    map BadValue dict Decode.value
    in
    Decode.andThen foldFun prevDec


primaryKey : Record -> Maybe Value
primaryKey record =
    Dict.values record
        |> List.filterMap primaryKeyHelp
        |> List.head


primaryKeyHelp : Value -> Maybe Value
primaryKeyHelp value =
    case value of
        PPrimaryKey _ ->
            Just value

        _ ->
            Nothing
