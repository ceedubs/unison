module Elmz.Signal where


-- debugging
import Debug
import Elmz.Maybe
import List
import List ((::))
import Maybe
import Execute
import Mouse
import Result
import Signal (..)
import Text
import Time
import Time (Time)

{-| Accumulates into a list using `foldp` during regions where `cond`
    is `True`, otherwise emits the empty list. -}
accumulateWhen : Signal Bool -> Signal a -> Signal (List a)
accumulateWhen cond a = foldpWhen cond (::) [] a |> map List.reverse

asyncUpdate : (Signal req -> Signal (model -> (Maybe req, model)))
           -> Signal (model -> (Maybe req, model))
           -> req
           -> model
           -> Signal model
asyncUpdate responseActions actions req0 model0 =
  let reqs = channel req0
      mergedActions = merge actions (responseActions (subscribe reqs))
      step action (_,model) =
        let (req, model') = action model
        in (Maybe.map (send reqs) req, model')
      modelsWithMsgs = foldp step (Nothing,model0) mergedActions
      msgs = Execute.schedule (map (Maybe.withDefault Execute.noop) (justs (map fst modelsWithMsgs)))
  in during (map snd modelsWithMsgs) msgs

{-| Alternate sending `input` through `left` or `right` signal transforms,
    merging their results. -}
alternate : (Signal (Maybe a) -> Signal c)
         -> (Signal (Maybe b) -> Signal c)
         -> Signal (Result a b)
         -> Signal c
alternate left right input =
  let l e = case e of Err e -> Just e
                      Ok _ -> Nothing
      r = Result.toMaybe
      ls = justs (l <~ input)
      rs = justs (r <~ input)
  in merge (left ls) (right rs)

{-| Count the number of events in the input signal. -}
count : Signal a -> Signal Int
count a = foldp (\_ n -> n + 1) 0 a

{-| Delay the input `Signal` by one unit. -}
delay : a -> Signal a -> Signal a
delay h s =
  let go a {prev,cur} = { cur = prev, prev = a }
  in foldp go { prev = h, cur = h } s
  |> map .cur

{-| Only emit when the input signal transitions from `True` to `False`. -}
downs : Signal Bool -> Signal Bool
downs s = dropIf identity True s

{-| Emits an event whenever there are two events that occur within `within` time of each other. -}
doubleWithin : Time -> Signal s -> Signal ()
doubleWithin within s =
  let ts = map fst (Time.timestamp s)
      f t1 t2 = case t1 of
        Nothing -> False
        Just t1 -> if t2 - t1 < within then True else False
  in map2 f (delay Nothing (map Just ts)) ts
     |> keepIf identity False
     |> map (always ())

{-| Evaluate the second signal for its effects, but return the first signal. -}
during : Signal a -> Signal b -> Signal a
during a b = map2 always a (sampleOn (constant ()) b)

{-| Emit from `t` if `cond` is `True`, otherwise emit from `f`. -}
choose : Signal Bool -> Signal a -> Signal a -> Signal a
choose cond t f =
  let go cond a a2 = if cond then a else a2
  in go <~ cond ~ t ~ f

{-| Spikes `True` for one tick when `a` event fires, otherwise is `False`. -}
changed : Signal a -> Signal Bool
changed a =
  merge (always False <~ Time.delay 0 a)
        (always True <~ a)

clickLocations : Signal (Int,Int)
clickLocations = sampleOn Mouse.clicks (map2 always Mouse.position Mouse.clicks)

events : Signal a -> Signal (Maybe a)
events s =
  let f b a = if b then Just a else Nothing
  in map2 f (changed s) s

{-| Accumulate using `foldp` in between events generated by `reset`. Each `reset`
    event sets the `b` state back to `z`. -}
foldpBetween : Signal r -> (a -> b -> b) -> b -> Signal a -> Signal b
foldpBetween reset f z a =
  let f' a b = case a of
    Nothing -> z
    Just a -> f a b
  in foldp f' z (map (always Nothing) reset `merge` map Just a)

{-| Accumulate using `foldp` in between events generated by `reset`. Each `reset`
    event sets the `b` state back to the current value of `z`. -}
foldpBetween' : Signal r -> (a -> b -> b) -> Signal b -> Signal a -> Signal (Maybe b)
foldpBetween' reset f z a =
  let f' (a,z) b = case b of
    Nothing -> Just (f a z)
    Just b -> Just (f a b)
  in foldpBetween reset f' Nothing (map2 (,) a z)

{-| Accumulates using `foldp` during regions where `cond` is `True`,
    starting with the value `z`, otherwise emits `z`. -}
foldpWhen : Signal Bool -> (a -> b -> b) -> b -> Signal a -> Signal b
foldpWhen cond f z a =
  let go (cond,a) b = if cond then f a b else z
  in foldp go z (map2 (,) cond a)

{-| Like `foldpWhen`, but uses `z` as the starting value during 'live'
    regions, and emits `Nothing` when `cond` is `False`. -}
foldpWhen' : Signal Bool -> (a -> b -> b) -> Signal b -> Signal a -> Signal (Maybe b)
foldpWhen' cond f z a =
  let go (a,z) b = case b of Nothing -> Just (f a z)
                             Just b  -> Just (f a b)
  in foldpWhen cond go Nothing (map2 (,) a z)

fromMaybe : Signal a -> Signal (Maybe a) -> Signal a
fromMaybe = map2 Elmz.Maybe.fromMaybe

flattenMaybe : Signal (Maybe (Maybe a)) -> Signal (Maybe a)
flattenMaybe s = fromMaybe (constant Nothing) s

{-| Ignore any events of `Nothing`. -}
justs : Signal (Maybe a) -> Signal (Maybe a)
justs s = keepIf (Maybe.map (always True) >> Maybe.withDefault False) Nothing s

loop : (Signal a -> Signal s -> Signal (b,s)) -> s -> Signal a -> Signal b
loop f s a =
  let chan = channel s
      bs = f a (sampleOn a (subscribe chan)) -- Signal (b,s)
  in map2 always (map fst bs)
                 (Execute.complete (map (\(_,s) -> send chan s) bs))

map2r : (a -> b -> c) -> Signal a -> Signal b -> Signal c
map2r f a b = sampleOn b (map2 f a b)

{-| When the input is `False`, convert the signal to `Nothing`. -}
mask : Signal Bool -> Signal a -> Signal (Maybe a)
mask = map2 (\b a -> if b then Just a else Nothing)

{-| Merge two signals, using the combining function if any events co-occcur. -}
mergeWith : (a -> a -> a) -> Signal a -> Signal a -> Signal a
mergeWith resolve left right =
  let boolLeft  = always True <~ left
      boolRight = always False <~ right
      bothUpdated = (/=) <~ merge boolLeft boolRight ~ merge boolRight boolLeft
      exclusive = dropWhen bothUpdated Nothing (Just <~ merge left right)
      overlap = keepWhen bothUpdated Nothing (Just <~ map2 resolve left right)
      combine m1 m2 = case Maybe.oneOf [m1, m2] of
        Just a -> a
        Nothing -> List.head [] -- impossible
  in combine <~ exclusive ~ overlap

{-| Merge two signals, composing the functions if any events co-occcur. -}
mergeWithBoth : Signal (a -> a) -> Signal (a -> a) -> Signal (a -> a)
mergeWithBoth = mergeWith (>>)

{-| Merge the two signals. If events co-occur, emits `(Just a, Just b)`,
otherwise emits `(Just a, Nothing)` or `(Nothing, Just b)`. -}
oneOrBoth : Signal a -> Signal b -> Signal (Maybe a, Maybe b)
oneOrBoth a b =
  let combine a b = case a of
        (Nothing,_) -> b
        (Just a,_) -> case b of
          (_, Nothing) -> (Just a, Nothing)
          (_, Just b) -> (Just a, Just b)
  in mergeWith combine (map (\a -> (Just a, Nothing)) a)
                       (map (\b -> (Nothing, Just b)) b)

{-| A signal which emits a single event after a specified time. -}
pulse : Time -> Signal ()
pulse time = Time.delay time start

{-| Emit updates to `s` only when it moves outside the current bin,
    according to the function `within`. Otherwise emit no update but
    take on the value `Nothing`. -}
quantize : (a -> r -> Bool) -> Signal r -> Signal a -> Signal (Maybe a)
quantize within bin s =
  let f range a = if a `within` range then Nothing else Just a
  in dropIf (Maybe.map (always False) >> Maybe.withDefault True) Nothing (f <~ bin ~ s)

{-| Repeat updates to a signal after it has remained steady for `t`
    elapsed time, and only if the current value tests true against `f`. -}
repeatAfterIf : Time -> number -> (a -> Bool) -> Signal a -> Signal a
repeatAfterIf time fps f s =
  let repeatable = map f s
      delayedRep = repeatable |> keepIf identity False |> Time.since time |> map not
      resetDelay = merge (always False <~ s) delayedRep
      repeats = Time.fpsWhen fps ((&&) <~ repeatable ~ dropRepeats resetDelay)
  in sampleOn repeats s

{-| A signal which emits a single event on or immediately after program start. -}
start : Signal ()
start =
  let chan = channel ()
      msg = send chan ()
  in sampleOn (subscribe chan)
              (map2 always (constant ()) (Execute.schedule (constant msg)))

{-| Only emit updates of `s` when it settles into a steady state with
    no updates within the period `t`. Useful to avoid propagating updates
    when a value is changing too rapidly. -}
steady : Time -> Signal a -> Signal a
steady t s = sampleOn (Time.since t s |> dropIf identity False) s

{-| Like `sampleOn`, but the output signal refreshes whenever either signal updates. -}
sampleOnMerge : Signal a -> Signal b -> Signal b
sampleOnMerge a b = map2 always b a

transitions : Signal a -> Signal Bool
transitions = transitionsBy (==)

{-| `True` when the signal emits a value which differs from its previous value
    according to `same`, `False` otherwise. -}
transitionsBy : (a -> a -> Bool) -> Signal a -> Signal Bool
transitionsBy same s =
  let f prev cur = case prev of
    Nothing -> True
    Just prev -> same prev cur
  in map2 f (delay Nothing (map Just s)) s

{-| Alternate emitting `b` then `not b` with each event emitted by `s`,
    starting by emitting `b`. -}
toggle : Bool -> Signal a -> Signal Bool
toggle b s = foldp (\_ b -> not b) b s

tuple2 : Signal a -> Signal b -> Signal (a,b)
tuple2 s s2 = (,) <~ s ~ s2

{-| Spikes `False` for one tick when `a` event fires, otherwise is `True`. -}
unchanged : Signal a -> Signal Bool
unchanged a = map not (changed a)

{-| Only emit when the input signal transitions from `False` to `True`. -}
ups : Signal Bool -> Signal Bool
ups s = keepIf identity False s

zip : Signal a -> Signal b -> Signal (a,b)
zip = map2 (,)

dumbSum : Signal Int -> Signal Int
dumbSum a =
  loop (\a acc -> map2 (+) a acc |> map (\a -> (a,a))) 0 a

main =
  let c = always 1 <~ Mouse.clicks
  in Text.plainText << toString <~ dumbSum c
