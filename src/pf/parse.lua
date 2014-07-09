module(...,package.seeall)

local function skip_whitespace(str, pos)
   while pos <= #str and str:match('^%s', pos) do
      pos = pos + 1
   end
   return pos
end

local function set(...)
   local ret = {}
   for k, v in pairs({...}) do ret[v] = true end
   return ret
end

local function record(type, ...)
   return { type = type, ... }
end

local punctuation = set(
   '(', ')', '[', ']', '!', '!=', '<', '<=', '>', '>=', '=',
   '+', '-', '*', '/', '%', '&', '|', '^', '&&', '||', '<<', '>>'
)

local function lex_host_or_keyword(str, pos)
   local name, next_pos = str:match("^([%w.-]+)()", pos)
   assert(name, "failed to parse hostname or keyword at "..pos)
   assert(name:match("^%w", 1, 1), "bad hostname or keyword "..name)
   assert(name:match("^%w", #name, #name), "bad hostname or keyword "..name)
   return tonumber(name, 10) or name, next_pos
end

local function lex_ipv4_or_host(str, pos)
   local function lex_byte(str)
      local byte = tonumber(str, 10)
      if byte >= 256 then return nil end
      return byte
   end
   local digits, dot = str:match("^(%d%d?%d?)()%.", pos)
   if not digits then return lex_host_or_keyword(str, start_pos) end
   local addr = record('ipv4')
   local byte = lex_byte(digits)
   if not byte then return lex_host_or_keyword(str, pos) end
   table.insert(addr, byte)
   pos = dot
   for i=1,3 do
      local digits, dot = str:match("^%.(%d%d?%d?)()", pos)
      if not digits then break end
      local byte = assert(lex_byte(digits), "failed to parse ipv4 addr")
      table.insert(addr, byte)
      pos = dot
   end
   local terminators = " \t\r\n)/"
   assert(pos > #str or terminators:find(str:sub(pos, pos), 1, true),
          "unexpected terminator for ipv4 address")
   return addr, pos
end

local function lex_ipv6(str, pos)
   local addr = record('ipv6')
   -- FIXME: Currently only supporting fully-specified IPV6 names.
   local digits, dot = str:match("^(%x%x%x%x)()%:", pos)
   assert(digits, "failed to parse ipv6 address at "..pos)
   table.insert(addr, tonumber(digits, 16))
   pos = dot
   for i=1,15 do
      local digits, dot = str:match("^%:(%x%x%x%x)()", pos)
      assert(digits, "failed to parse ipv6 address at "..pos)
      table.insert(addr, tonumber(digits, 16))
      pos = dot
   end
   local terminators = " \t\r\n)/"
   assert(pos > #str or terminators:find(str:sub(pos, pos), 1, true),
          "unexpected terminator for ipv6 address")
   return addr, pos
end

local function lex_ehost(str, pos)
   local addr = record('ehost')
   local digits, dot = str:match("^(%x%x)()%:", pos)
   assert(digits, "failed to parse ethernet host address at "..pos)
   table.insert(addr, tonumber(digits, 16))
   pos = dot
   for i=1,5 do
      local digits, dot = str:match("^%:(%x%x)()", pos)
      assert(digits, "failed to parse ethernet host address at "..pos)
      table.insert(addr, tonumber(digits, 16))
      pos = dot
   end
   local terminators = " \t\r\n)/"
   assert(pos > #str or terminators:find(str:sub(pos, pos), 1, true),
          "unexpected terminator for ethernet host address")
   return addr, pos
end

local function lex_addr(str, pos)
   local start_pos = pos
   if str:match("^%d%d?%d?%.", pos) then
      return lex_ipv4_or_host(str, pos)
   elseif str:match("^%x%x%x%x%:", pos) then
      return lex_ipv6(str, pos)
   elseif str:match("^%x%x%:", pos) then
      return lex_ehost(str, pos)
   else
      return lex_host_or_keyword(str, pos)
   end
end

local number_terminators = " \t\r\n)]!<>=+-*/%&|^"

local function lex_number(str, pos, base)
   local res = 0
   local i = pos
   while i <= #str do
      local chr = str:sub(i,i)
      local n = tonumber(chr, base)
      if n then
         res = res * base + n
         assert(res <= 0xffffffff, 'integer too large: '..res)
         i = i + 1
      elseif str:match("^[%a_.]", i) then
         return nil, i
      else
         return res, i
      end
   end
   return res, i  -- EOS
end

local function lex_hex(str, pos)
   local ret, next_pos = lex_number(str, pos, 16)
   assert(ret, "unexpected end of hex literal at "..pos)
   return ret, next_pos
end

local function lex_octal_or_addr(str, pos, in_brackets)
   local ret, next_pos = lex_number(str, pos, 8)
   if not ret then
      if in_brackets then return lex_host_or_keyword(str, pos) end
      return lex_addr(str, pos)
   end
   return ret, next_pos
end

local function lex_decimal_or_addr(str, pos, in_brackets)
   local ret, next_pos = lex_number(str, pos, 10)
   if not ret then
      if in_brackets then return lex_host_or_keyword(str, pos) end
      return lex_addr(str, pos)
   end
   return ret, next_pos
end

local function lex(str, pos, opts, in_brackets)
   -- EOF.
   if pos > #str then return nil, pos end

   -- Non-alphanumeric tokens.
   local two = str:sub(pos,pos+1)
   if punctuation[two] then return two, pos+2 end
   local one = str:sub(pos,pos)
   if punctuation[one] then return one, pos+1 end

   -- If we are in brackets, then : separates an expression from an
   -- access size.  Otherwise it separates parts of an IPv6 address.
   if in_brackets and one == ':' then return one, pos+1 end

   -- Numeric literals or net addresses.
   if opts.maybe_arithmetic and one:match('^%d') then
      if two == ('0x') then
         return lex_hex(str, pos+2)
      elseif two:match('^0%d') then
         return lex_octal_or_addr(str, pos, in_brackets)
      else
         return lex_decimal_or_addr(str, pos, in_brackets)
      end
   end

   -- IPV6 net address beginning with [a-fA-F].
   if not in_brackets and str:match('^%x?%x?%:', pos) then
      return lex_ipv6(str, pos)
   end

   -- "len" is the only bare name that can appear in an arithmetic
   -- expression.  "len-1" lexes as { 'len', '-', 1 } in arithmetic
   -- contexts, but { "len-1" } otherwise.
   if opts.maybe_arithmetic and str:match("^len", pos) then
      if pos + 3 > #str or not str:match("^[%w.]", pos+3) then
         return 'len', pos+3
      end
   end

   -- Again, if we're in brackets, there won't be an IPv6 address.
   if in_brackets then return lex_host_or_keyword(str, pos) end

   -- Keywords or addresses.
   return lex_addr(str, pos)
end

local function tokens(str)
   local pos, next_pos = 1, nil
   local peeked = nil
   local brackets = 0
   local function peek(opts)
      if not next_pos then
         pos = skip_whitespace(str, pos)
         peeked, next_pos = lex(str, pos, opts or {}, brackets > 0)
         if peeked == '[' then brackets = brackets + 1 end
         if peeked == ']' then brackets = brackets - 1 end
         assert(next_pos, "next pos is nil")
      end
      return peeked
   end
   local function next(opts)
      local tok = assert(peek(opts), "unexpected end of filter string")
      pos, next_pos = next_pos, nil
      return tok
   end
   local function consume(expected, opts)
      local tok = next(opts)
      assert(tok == expected, "expected "..expected..", got:", tok)
   end
   local function check(expected, opts)
      if peek(opts) ~= expected then return false end
      next()
      return true
   end
   return { peek = peek, next = next, consume = consume, check = check }
end

local addressables = set(
   'arp', 'rarp', 'wlan', 'ether', 'fddi', 'tr', 'ppp',
   'slip', 'link', 'radio', 'ip', 'ip6', 'tcp', 'udp', 'icmp'
)

local function unimplemented(lexer, tok)
   error("not implemented: "..tok)
end

local function nullary()
   return function(lexer, tok)
      return record(tok)
   end
end

local function unary(parse_arg)
   return function(lexer, tok)
      return record(tok, parse_arg(lexer))
   end
end

function parse_host_arg(lexer)
   local arg = lexer.next()
   if type(arg) == 'string' or arg.type == 'ipv4' or arg.type == 'ipv6' then
      return arg
   end
   error('invalid host', arg)
end

function parse_int_arg(lexer, max_len)
   local ret = lexer.next()
   assert(type(ret) == 'number', 'expected a number', ret)
   if max_len then assert(ret <= max_len, 'out of range '..ret) end
   return ret
end

function parse_uint16_arg(lexer) return parse_int_arg(lexer, 0xffff) end

function parse_net_arg(lexer)
   local arg = lexer.next()
   if arg.type == 'ipv4' or arg.type == 'ipv6' then
      if lexer.check('/') then
         local len = parse_int_arg(lexer, arg.type == 'ipv4' and 32 or 128)
         return record(arg.type..'/len', arg, len)
      elseif lexer.check('mask') then
         lexer.next()
         local mask = lexer.next()
         assert(mask.type == arg.type, 'bad mask', mask)
         return record(arg.type..'/mask', arg, mask)
      else
         return arg
      end
   elseif type(arg) == 'string' then
      error('named nets currently unsupported ' .. arg)
   else
      assert(type(arg) == 'number')  -- `net 10'
      error('bare numbered nets currently unsupported', arg)
   end
end

local parse_port_arg = parse_uint16_arg

local function parse_portrange_arg(lexer)
   local start = parse_port_arg(lexer)
   lexer.consume('-')
   return record('portrange', start, parse_port_arg(lexer))
end

local function parse_ehost_arg(lexer)
   local arg = lexer.next()
   if type(arg) == 'string' or arg.type == 'ehost' then
      return arg
   end
   error('invalid ethernet host', arg)
end

local function table_parser(table, default)
   return function (lexer, tok)
      local subtok = lexer.peek()
      if table[subtok] then
         lexer.consume(subtok)
         return table[subtok](lexer, tok..'-'..subtok)
      end
      if default then return default(lexer, tok) end
      error("unknown "..tok.." type "..subtok)
   end
end

local ether_protos = set(
   'ip', 'ip6', 'arp', 'rarp', 'atalk', 'aarp', 'decnet', 'sca', 'lat',
   'mopdl', 'moprc', 'iso', 'stp', 'ipx', 'netbeui'
)

local function parse_ether_proto_arg(lexer)
   local arg = lexer.next()
   if type(arg) == 'number' or ether_protos[arg] then
      return arg
   end
   error('invalid ethernet proto', arg)
end

local ip_protos = set(
   'icmp', 'icmp6', 'igmp', 'igrp', 'pim', 'ah', 'esp', 'vrrp', 'udp', 'tcp'
)

local function parse_ip_proto_arg(lexer)
   local arg = lexer.next()
   if type(arg) == 'number' or ip_protos[arg] then
      return arg
   end
   error('invalid ip proto', arg)
end

local function simple_typed_arg_parser(expected)
   return function(lexer)
      local arg = lexer.next()
      if type(arg) == expected then return arg end
      error('expected a '..expected..' string, got '..type(arg))
   end
end

local parse_string_arg = simple_typed_arg_parser('string')

local function parse_decnet_host_arg(lexer)
   local arg = lexer.next()
   if type(arg) == 'string' then return arg end
   if arg.type == 'ipv4' then
      arg.type = 'decnet'
      assert(#arg == 2, "bad decnet address", arg)
      return arg
   end
   error('invalid decnet host', arg)
end

local llc_types = set(
   'i', 's', 'u', 'rr', 'rnr', 'rej', 'ui', 'ua',
   'disc', 'sabme', 'test', 'xis', 'frmr'
)

local function parse_llc(lexer, tok)
   local type = lexer.peek()
   if llc_types[type] then return record(tok, type) end
   return record(tok)
end

local pf_reasons = set(
   'match', 'bad-offset', 'fragment', 'short', 'normalize', 'memory'
)

local pf_actions = set(
   'pass', 'block', 'nat', 'rdr', 'binat', 'scrub'
)

local wlan_frame_types = set('mgt', 'ctl', 'data')
local wlan_frame_mgt_subtypes = set(
   'assoc-req', 'assoc-resp', 'reassoc-req', 'reassoc-resp',
   'probe-req', 'probe-resp', 'beacon', 'atim', 'disassoc', 'auth', 'deauth'
)
local wlan_frame_ctl_subtypes = set(
   'ps-poll', 'rts', 'cts', 'ack', 'cf-end', 'cf-end-ack'
)
local wlan_frame_data_subtypes = set(
   'data', 'data-cf-ack', 'data-cf-poll', 'data-cf-ack-poll', 'null',
   'cf-ack', 'cf-poll', 'cf-ack-poll', 'qos-data', 'qos-data-cf-ack',
   'qos-data-cf-poll', 'qos-data-cf-ack-poll', 'qos', 'qos-cf-poll',
   'quos-cf-ack-poll'
)

local wlan_directions = set('nods', 'tods', 'fromds', 'dstods')

local iso_proto_types = set('clnp', 'esis', 'isis')

local function parse_enum_arg(lexer, set)
   local arg = lexer.next()
   assert(set[arg], 'invalid argument: '..arg)
   return arg
end

local function enum_arg_parser(set)
   return function(lexer) return parse_enum_arg(lexer, set) end
end

local function parse_wlan_type(lexer, tok)
   local type = enum_arg_parser(wlan_frame_types)(lexer)
   if lexer.check('subtype') then
      local set
      if type == 'mgt' then set = wlan_frame_mgt_subtypes
      elseif type == 'mgt' then set = wlan_frame_ctl_subtypes
      else set = wlan_frame_data_subtypes end
      return record('type', type, enum_arg_parser(set)(lexer))
   end
   return record(tok, type)
end

local function parse_wlan_subtype(lexer, tok)
   local subtype = lexer.next()
   assert(wlan_frame_mgt_subtypes[subtype]
             or wlan_frame_ctl_subtypes[subtype]
             or wlan_frame_data_subtypes[subtype],
          'bad wlan subtype '..subtype)
   return record(tok, subtype)
end

local function parse_wlan_dir(lexer, tok)
   if (type(lexer.peek()) == 'number') then
      return record(tok, lexer.next())
   end
   return record(tok, parse_enum_arg(lexer, wlan_directions))
end

local function parse_optional_int(lexer, tok)
   if (type(lexer.peek()) == 'number') then
      return parser(tok, lexer.next())
   end
   return parser(tok)
end

local src_or_dst_types = {
   host = unary(parse_host_arg),
   net = unary(parse_net_arg),
   port = unary(parse_port_arg),
   portrange = unary(parse_portrange_arg)
}

local ether_types = {
   dst = unary(parse_ehost_arg),
   src = unary(parse_ehost_arg),
   host = unary(parse_ehost_arg),
   broadcast = nullary(),
   multicast = nullary(),
   proto = unary(parse_ether_proto_arg),
}

local ip_types = {
   proto = unary(parse_ip_proto_arg),
   protochain = unary(parse_proto_arg),
   broadcast = nullary(),
   multicast = nullary(),
}

local ip6_types = {
   proto = unary(parse_ip_proto_arg),
   protochain = unary(parse_proto_arg),
   multicast = nullary(),
}

local decnet_types = {
   src = unary(parse_decnet_host_arg),
   dst = unary(parse_decnet_host_arg),
   host = unary(parse_decnet_host_arg),
}

local wlan_types = {
   ra = unary(parse_ehost_arg),
   ta = unary(parse_ehost_arg),
   addr1 = unary(parse_ehost_arg),
   addr2 = unary(parse_ehost_arg),
   addr3 = unary(parse_ehost_arg),
   addr4 = unary(parse_ehost_arg),
}

local iso_types = {
   proto = unary(enum_arg_parser(iso_proto_types)),
   ta = unary(parse_ehost_arg),
   addr1 = unary(parse_ehost_arg),
   addr2 = unary(parse_ehost_arg),
   addr3 = unary(parse_ehost_arg),
   addr4 = unary(parse_ehost_arg),
}

local primitives = {
   dst = table_parser(src_or_dst_types),
   src = table_parser(src_or_dst_types),
   host = unary(parse_host_arg),
   ether = table_parser(ether_types),
   gateway = unary(parse_string_arg),
   net = unary(parse_net_arg),
   port = unary(parse_port_arg),
   portrange = unary(parse_portrange_arg),
   less = unary(parse_int_arg),
   greater = unary(parse_int_arg),
   ip = table_parser(ip_types, nullary()),
   ip6 = table_parser(ip6_types, nullary()),
   proto = unary(parse_proto_arg),
   tcp = nullary(),
   udp = nullary(),
   icmp = nullary(),
   protochain = unary(parse_proto_arg),
   arp = nullary(),
   rarp = nullary(),
   atalk = nullary(),
   aarp = nullary(),
   decnet = table_parser(decnet_types),
   iso = nullary(),
   stp = nullary(),
   ipx = nullary(),
   netbeui = nullary(),
   lat = nullary(),
   moprc = nullary(),
   mopdl = nullary(),
   llc = parse_llc,
   ifname = unary(parse_string_arg),
   on = unary(parse_string_arg),
   rnr = unary(parse_int_arg),
   rulenum = unary(parse_int_arg),
   reason = unary(enum_arg_parser(pf_reasons)),
   rset = unary(parse_string_arg),
   ruleset = unary(parse_string_arg),
   srnr = unary(parse_int_arg),
   subrulenum = unary(parse_int_arg),
   action = unary(enum_arg_parser(pf_actions)),
   wlan = table_parser(wlan_types),
   type = parse_wlan_type,
   subtype = parse_wlan_subtype,
   dir = unary(enum_arg_parser(wlan_directions)),
   vlan = parse_optional_int,
   mpls = parse_optional_int,
   pppoed = nullary(),
   pppoes = parse_optional_int,
   iso = table_parser(iso_types),
   clnp = nullary(),
   esis = nullary(),
   isis = nullary(),
   l1 = nullary(),
   l2 = nullary(),
   iih = nullary(),
   lsp = nullary(),
   snp = nullary(),
   csnp = nullary(),
   psnp = nullary(),
   vpi = unary(parse_int_arg),
   vci = unary(parse_int_arg),
   lane = nullary(),
   oamf4s = nullary(),
   oamf4e = nullary(),
   oamf4 = nullary(),
   oam = nullary(),
   metac = nullary(),
   bcc = nullary(),
   sc = nullary(),
   ilmic = nullary(),
   connectmsg = nullary(),
   metaconnect = nullary()
}

local function parse_primary_arithmetic(lexer, tok)
   tok = tok or lexer.next({maybe_arithmetic=true})
   if tok == '(' then
      local expr = parse_arithmetic(lexer)
      lexer.consume(')')
      return expr
   elseif tok == 'len' or type(tok) == 'number' then
      return tok
   elseif addressables[tok] then
      lexer.consume('[')
      local pos = parse_arithmetic(lexer)
      local size = 1
      if lexer.check(':') then
         if lexer.check(1) then size = 1
         elseif lexer.check(2) then size = 1
         else lexer.consume(4); size = 1 end
      end
      lexer.consume(']')
      return record('['..tok..']', pos, size)
   else
      error('bad token while parsing arithmetic expression', tok)
   end
end

local arithmetic_precedence = {
   ['*'] = 1, ['/'] = 1, ['%'] = 1,
   ['+'] = 2, ['-'] = 2,
   ['<<'] = 3, ['>>'] = 3,
   ['&'] = 4,
   ['^'] = 5,
   ['|'] = 6
}

local function parse_arithmetic(lexer, tok, max_precedence)
   local exp = parse_primary_arithmetic(lexer, tok)
   max_precedence = max_precedence or math.huge
   while true do
      local op = lexer.peek()
      local prec = arithmetic_precedence[op]
      if not prec or prec > max_precedence then return exp end
      lexer.consume(op)
      local rhs = parse_arithmetic(lexer, nil, prec - 1)
      exp = record(op, exp, rhs)
   end
end

local function parse_relop(lexer, tok)
   local lhs = parse_arithmetic(lexer, tok)
   local op = lexer.next()
   assert(set('>', '<', '>=', '<=', '=', '!=')[op],
          "expected a comparison operator, got", op)
   return record(op, lhs, parse_arithmetic(lexer))
end

local function parse_primitive_or_relop(lexer)
   local tok = lexer.next({maybe_arithmetic=true})
   if (type(tok) == 'number' or tok == 'len' or
       addressables[tok] and lexer.peek() == '[') then
      return parse_relop(lexer, tok)
   end

   local parser = primitives[tok]
   if parser then return parser(lexer, tok) end

   -- At this point the official pcap grammar is squirrely.  It says:
   -- "If an identifier is given without a keyword, the most recent
   -- keyword is assumed.  For example, `not host vs and ace' is
   -- short for `not host vs and host ace` and which should not be
   -- confused with `not (host vs or ace)`."  For now we punt on this
   -- part of the grammar.
   error("keyword elision not implemented")
end

local logical_precedence = {
   ['&&'] = 1, ['and'] = 1,
   ['||'] = 2, ['or'] = 2
}

local function parse_logical(lexer, max_precedence)
   local exp = parse_primitive_or_relop(lexer)
   max_precedence = max_precedence or math.huge
   while true do
      local op = lexer.peek()
      local prec = logical_precedence[op]
      if not prec or prec > max_precedence then return exp end
      lexer.consume(op)
      local rhs = parse_logical(lexer, prec - 1)
      exp = record(op, exp, rhs)
   end
end

local function parse_expr(lexer)
   if not lexer.peek({maybe_arithmetic=true}) then
      return nil
   elseif lexer.check('(') then
      local expr = parse_expr(lexer)
      lexer.consume(')')
      return expr
   elseif lexer.check('not') then
      return record('not', parse_expr(lexer))
   else
      return parse_logical(lexer)
   end
end

function parse(str)
   local lexer = tokens(str)
   local expr = parse_expr(tokens(str))
   assert(not lexer.peek(), "unexpected token", lexer.peek())
   return expr
end

function selftest ()
   print("selftest: pf.parse")
   local function check(expected, actual)
      assert(type(expected) == type(actual),
             "expected type "..type(expected).." but got "..type(actual))
      if type(expected) == 'table' then
         for k, v in pairs(expected) do check(v, actual[k]) end
      else
         assert(expected == actual, "expected "..expected.." but got "..actual)
      end
   end

   local function lex_test(str, elts, opts)
      local lexer = tokens(str)
      for i, val in ipairs(elts) do
         check(val, lexer.next(opts))
      end
      assert(not lexer.peek(opts), "more tokens, yo")
   end
   lex_test("ip", {"ip"}, {maybe_arithmetic=true})
   lex_test("len", {"len"}, {maybe_arithmetic=true})
   lex_test("len", {"len"}, {})
   lex_test("len-1", {"len-1"}, {})
   lex_test("len-1", {"len", "-", 1}, {maybe_arithmetic=true})
   lex_test("1-len", {1, "-", "len"}, {maybe_arithmetic=true})
   lex_test("1-len", {"1-len"}, {})
   lex_test("tcp port 80", {"tcp", "port", 80}, {})
   lex_test("tcp port 80 and (((ip[2:2] - ((ip[0]&0xf)<<2)) - ((tcp[12]&0xf0)>>2)) != 0)",
            { 'tcp', 'port', 80, 'and',
              '(', '(',
              '(',
              'ip', '[', 2, ':', 2, ']', '-',
              '(', '(', 'ip', '[', 0, ']', '&', 15, ')', '<<', 2, ')',
              ')',
              '-',
              '(', '(', 'tcp', '[', 12, ']', '&', 240, ')', '>>', 2, ')',
              ')', '!=', 0, ')'
            }, {maybe_arithmetic=true})
   lex_test("host 127.0.0.1", { 'host', { type='ipv4', 127, 0, 0, 1 } })
   lex_test("net 10.0.0.0/24", { 'net', { type='ipv4', 10, 0, 0, 0 }, '/', 24 })

   local function parse_test(str, elts) check(elts, parse_expr(tokens(str))) end
   parse_test("host 127.0.0.1",
              { type='host', { type='ipv4', 127, 0, 0, 1 } })
   parse_test("src host 127.0.0.1",
              { type='src-host', { type='ipv4', 127, 0, 0, 1 } })
   parse_test("src net 10.0.0.0/24",
              { type='src-net',
                { type='ipv4/len', { type='ipv4', 10, 0, 0, 0 }, 24 }})
   parse_test("ether proto rarp",
              { type='ether-proto', 'rarp' })
   parse_test("decnet host 10.23",
              { type='decnet-host', { type='decnet', 10, 23 } })
   parse_test("ip proto icmp",
              { type='ip-proto', 'icmp' })
   parse_test("ip",
              { type='ip' })
   parse_test("type mgt",
              { type='type', 'mgt' })
   parse_test("type mgt subtype deauth",
              { type='type', 'mgt', 'deauth' })
   parse_test("1+1=2",
              { type='=', { type='+', 1, 1 }, 2 })
   parse_test("1+2*3+4=5",
              { type='=', { type='+', { type='+', 1, { type='*', 2, 3 } }, 4 }, 5 })
   parse_test("1+1=2 and tcp",
              { type='and', { type='=', { type='+', 1, 1 }, 2 }, { type='tcp' } })
   print("OK")
end