module PostgrestAdmin exposing (Model, Msg, application, applicationParams)

import Browser
import Browser.Navigation as Nav
import Dict
import Dict.Extra as Dict
import Form exposing (Form(..))
import Html exposing (Html, a, aside, div, h1, li, pre, text, ul)
import Html.Attributes exposing (class, href, style)
import Inflect as String
import Json.Decode as Decode exposing (Decoder, Value)
import Listing exposing (Listing)
import Notification exposing (Notification)
import Postgrest.Client as PG
import Postgrest.Resource.Client exposing (Client)
import Postgrest.Schema as Schema exposing (Schema)
import Postgrest.Schema.Definition exposing (Definition)
import PostgrestAdmin.Config as Config exposing (Config)
import PostgrestAdmin.OuterMsg as OuterMsg exposing (OuterMsg)
import String.Extra as String
import Task
import Time
import Url exposing (Url)
import Url.Parser as Parser exposing ((</>), Parser)
import Utils.Task exposing (Error(..), attemptWithError, fail)


type Msg
    = SchemaFetched Schema
    | ListingChanged Listing.Msg
    | FormChanged Form.Msg
    | NotificationChanged Notification.Msg
    | LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | Failed Error


type Route
    = Root
    | LoadingDefinition String (Definition -> Route)
    | Listing Listing
    | FormLoading Form String
    | Form Form
    | NotFound


type alias Params =
    { init : Value -> Url.Url -> Nav.Key -> ( Model, Cmd Msg )
    , view : Model -> Browser.Document Msg
    , update : Msg -> Model -> ( Model, Cmd Msg )
    , subscriptions : Model -> Sub Msg
    , onUrlRequest : Browser.UrlRequest -> Msg
    , onUrlChange : Url -> Msg
    }


type alias Model =
    Client
        { route : Route
        , key : Nav.Key
        , notification : Notification
        , decodingError : Maybe Decode.Error
        }


application : Decoder Config -> Program Value Model Msg
application decoder =
    applicationParams decoder |> Browser.application


applicationParams : Decoder Config -> Params
applicationParams decoder =
    { init = init decoder
    , update = update
    , view = view
    , subscriptions = subscriptions
    , onUrlRequest = LinkClicked
    , onUrlChange = UrlChanged
    }


init : Decoder Config -> Value -> Url.Url -> Nav.Key -> ( Model, Cmd Msg )
init decoder flags url key =
    let
        makeModel config =
            { route = Root
            , key = key
            , schema = Dict.fromList []
            , host = config.url
            , authScheme = config.authScheme
            , notification = Notification.none
            , decodingError = Nothing
            }
    in
    case Decode.decodeValue decoder flags of
        Ok config ->
            let
                model =
                    makeModel config
            in
            ( { model | route = getRoute url model }
            , Schema.getSchema model.host
                |> attemptWithError Failed SchemaFetched
            )

        Err error ->
            let
                model =
                    makeModel Config.default
            in
            ( { model | decodingError = Just error }, Cmd.none )



-- Update


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        SchemaFetched schema ->
            navigate { model | schema = schema }

        ListingChanged innerMsg ->
            let
                updateFun =
                    Listing.update model innerMsg
                        >> mapNested Listing ListingChanged model
                        >> handleOuterMsg (Listing.outerMsg innerMsg)
            in
            toListing model
                |> Maybe.map updateFun
                |> Maybe.withDefault ( model, Cmd.none )

        FormChanged innerMsg ->
            let
                updateFun =
                    Form.update model innerMsg
                        >> mapNested Form FormChanged model
                        >> handleOuterMsg (Form.outerMsg innerMsg)
            in
            toForm model
                |> Maybe.map updateFun
                |> Maybe.withDefault ( model, Cmd.none )

        NotificationChanged innerMsg ->
            updateNotification innerMsg model

        LinkClicked urlRequest ->
            case urlRequest of
                Browser.Internal url ->
                    ( model, Nav.pushUrl model.key <| Url.toString url )

                Browser.External href ->
                    ( model, Nav.load href )

        UrlChanged url ->
            navigate { model | route = getRoute url model }

        Failed err ->
            failed err model


navigate : Model -> ( Model, Cmd Msg )
navigate model =
    case model.route of
        LoadingDefinition resourcesName makeRoute ->
            case Dict.get resourcesName model.schema of
                Just definition ->
                    navigate { model | route = makeRoute definition }

                Nothing ->
                    ( model, fail Failed <| BadSchema resourcesName )

        Listing listing ->
            Listing.fetch model listing
                |> mapNested Listing ListingChanged model

        FormLoading form id ->
            ( model, Form.fetch model form id |> Cmd.map FormChanged )

        _ ->
            ( model, Cmd.none )


mapNested :
    (a -> Route)
    -> (innerMsg -> Msg)
    -> Model
    -> ( a, Cmd innerMsg )
    -> ( Model, Cmd Msg )
mapNested makeRoute makeMsg model ( a, cmd ) =
    ( { model | route = makeRoute a }
    , Cmd.map makeMsg cmd
    )


handleOuterMsg : OuterMsg -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
handleOuterMsg msg ( model, cmd ) =
    case msg of
        OuterMsg.RequestFailed err ->
            failed err model

        OuterMsg.NotificationChanged notificationMsg ->
            updateNotification notificationMsg model

        OuterMsg.Pass ->
            ( model, cmd )


failed : Error -> Model -> ( Model, Cmd Msg )
failed err model =
    case err of
        PGError (PG.BadStatus 401 _ { message }) ->
            case message of
                Just "JWT expired" ->
                    ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


updateNotification : Notification.Msg -> Model -> ( Model, Cmd Msg )
updateNotification msg model =
    ( { model | notification = Notification.update msg }, Cmd.none )


toListing : Model -> Maybe Listing
toListing { route } =
    case route of
        Listing listing ->
            Just listing

        _ ->
            Nothing


toForm : Model -> Maybe Form
toForm { route } =
    case route of
        FormLoading form _ ->
            Just form

        Form form ->
            Just form

        _ ->
            Nothing



-- View


view : Model -> Browser.Document Msg
view model =
    { title = "Admin"
    , body =
        [ div
            [ class "main-container" ]
            [ sideMenu model
            , div [ class "main-area" ] (body model)
            ]
        ]
    }


body : Model -> List (Html Msg)
body model =
    case model.decodingError of
        Just err ->
            [ h1 [] [ text "Init failed" ]
            , pre
                [ class "parse-errors" ]
                [ text (Decode.errorToString err) ]
            ]

        Nothing ->
            [ Notification.view model.notification
                |> Html.map NotificationChanged
            , mainContent model
            ]


sideMenu : Model -> Html Msg
sideMenu model =
    aside
        [ class "resources-menu" ]
        [ ul [] (Dict.keys model.schema |> List.sort |> List.map menuItem) ]


menuItem : String -> Html Msg
menuItem name =
    li
        []
        [ a [ href <| "/" ++ name ] [ text <| String.humanize name ] ]


mainContent : Model -> Html Msg
mainContent model =
    case model.route of
        Root ->
            text ""

        LoadingDefinition _ _ ->
            loading

        Listing listing ->
            Html.map ListingChanged <| Listing.view listing

        FormLoading _ _ ->
            loading

        Form form ->
            Html.map FormChanged <| Form.view form

        NotFound ->
            notFound


notFound : Html Msg
notFound =
    text "Not found"


loading : Html Msg
loading =
    text ""



-- Subscriptions


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none



-- Routes


getRoute : Url -> Model -> Route
getRoute url model =
    Parser.parse (routeParser url model) url |> Maybe.withDefault NotFound


routeParser : Url -> Model -> Parser (Route -> a) a
routeParser url model =
    Parser.oneOf
        [ Parser.map Root Parser.top
        , Parser.map (makeListingRoute model url) Parser.string
        , formRouteParser model
        ]


makeListingRoute : Model -> Url -> String -> Route
makeListingRoute model url resourcesName =
    let
        modify =
            case model.route of
                Listing listing ->
                    if Listing.isSearchVisible listing then
                        Listing.showSearch

                    else
                        Listing.hideSearch

                _ ->
                    Listing.showSearch
    in
    LoadingDefinition resourcesName
        (Listing.init resourcesName url.query >> modify >> Listing)


formRouteParser : Model -> Parser (Route -> a) a
formRouteParser model =
    Parser.map (\res id -> LoadingDefinition res (makeFormRoute res id model))
        (Parser.string </> Parser.string)


makeFormRoute : String -> String -> Model -> Definition -> Route
makeFormRoute resources id model definition =
    let
        params =
            { resourcesName = resources
            , definition = definition
            }

        form =
            Form.fromDefinition params definition
    in
    if id == "new" then
        Form form

    else
        FormLoading form id
