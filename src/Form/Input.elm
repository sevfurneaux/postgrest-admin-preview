module Form.Input exposing (Input, Msg, input, updateRecord)

import Dict
import Field exposing (Field)
import Html exposing (..)
import Html.Attributes
    exposing
        ( attribute
        , checked
        , class
        , classList
        , for
        , id
        , type_
        , value
        )
import Html.Events exposing (onInput)
import Iso8601
import Maybe.Extra as Maybe
import Postgrest.Resource exposing (Resource)
import Postgrest.Value exposing (Value(..))
import String.Extra as String


type Msg
    = Changed String Field


type alias Input =
    { name : String
    , attributes : List (Html.Attribute Msg)
    }


updateRecord : Msg -> Resource -> Resource
updateRecord (Changed name field) record =
    Dict.insert name field record


input : Input -> Field -> Html Msg
input params field =
    case field.value of
        PString maybe ->
            inputHelp params "text" field maybe

        PFloat maybe ->
            Maybe.map String.fromFloat maybe
                |> inputHelp params "number" field

        PInt maybe ->
            Maybe.map String.fromInt maybe
                |> inputHelp params "number" field

        PBool maybe ->
            let
                attr =
                    Maybe.map checked maybe
                        |> Maybe.withDefault (attribute "" "")
            in
            inputHelp
                { params | attributes = attr :: params.attributes }
                "checkbox"
                field
                Nothing

        PTime maybe ->
            Maybe.map (Iso8601.fromTime >> String.slice 0 19) maybe
                |> inputHelp params "datetime-local" field

        _ ->
            text ""


inputHelp : Input -> String -> Field -> Maybe String -> Html Msg
inputHelp { attributes, name } t field mstring =
    let
        input_ =
            Html.input
                (attributes
                    ++ [ onInput <| (Changed name << Field.update field)
                       , id name
                       , type_ t
                       , value <| Maybe.withDefault "" mstring
                       ]
                )
                []

        labelText =
            if field.required then
                String.humanize name ++ "*"

            else
                String.humanize name

        error =
            field.error
                |> Maybe.map (text >> List.singleton >> p [ class "error" ])
                |> Maybe.withDefault (text "")
    in
    div
        [ class "field"
        , classList [ ( "with-error", Maybe.isJust field.error ) ]
        ]
        [ label [ for name ] [ text labelText ], input_, error ]
