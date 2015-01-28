# ip6 proto 47


## BPF

```
000: A = P[12:2]
001: if (A == 34525) goto 2 else goto 8
002: A = P[20:1]
003: if (A == 47) goto 7 else goto 4
004: if (A == 44) goto 5 else goto 8
005: A = P[54:1]
006: if (A == 47) goto 7 else goto 8
007: return 65535
008: return 0
```


## BPF cross-compiled to Lua

```
return function (P, length)
   local A = 0
   if 14 > length then return 0 end
   A = bit.bor(bit.lshift(P[12], 8), P[12+1])
   if not (A==34525) then goto L7 end
   if 21 > length then return 0 end
   A = P[20]
   if (A==47) then goto L6 end
   if not (A==44) then goto L7 end
   if 55 > length then return 0 end
   A = P[54]
   if not (A==47) then goto L7 end
   ::L6::
   do return 65535 end
   ::L7::
   do return 0 end
   error("end of bpf")
end
```


## Direct pflang compilation

```
return function(P,length)
   if length < 54 then return false end
   if cast("uint16_t*", P+12)[0] ~= 56710 then return false end
   local var2 = P[20]
   if var2 == 47 then return true end
   if length < 55 then return false end
   if var2 ~= 44 then return false end
   return P[54] == 47
end

```
