#!/usr/bin/env python3

import sys
if sys.version_info[0] != 3:
    print("Error: This script requires python 3, current version is {}".format(sys.version))
    sys.exit(1)

import json
import os
import re
import textwrap

from collections import namedtuple


### Begin Pointer Rules
## Types
class Context:
    def __repr__(self):
        result = [
            'Struct',
            'Field',
            'Function',
            'Param',
            'Template',
            'Typedef'
        ][self.type-1] + ' '

        if self.name:
            result += self.name
        else:
            result += '<anon>'

        if self.parent is None:
            return result
        return repr(self.parent) + ' ' + result

class Always:
    def __eq__(self, test):
        return True

    def __repr__(self):
        return 'Always()'

class Not:
    def __init__(self, match):
        self.match = match

    def __eq__(self, text):
        return not (self.match == text)

    def __repr__(self):
        return 'Not(' + repr(self.match) + ')'

class Contains:
    def __init__(self, text):
        self.text = text

    def __eq__(self, test):
        return self.text in test

    def __repr__(self):
        return 'Contains(' + repr(self.text) + ')'

class StartsWith:
    def __init__(self, text):
        self.text = text

    def __eq__(self, test):
        return test.startswith(self.text)

    def __repr__(self):
        return 'StartsWith(' + repr(self.text) + ')'

class EndsWith:
    def __init__(self, text):
        self.text = text

    def __eq__(self, test):
        return test.endswith(self.text)

    def __repr__(self):
        return 'EndsWith(' + repr(self.text) + ')'

class Regex:
    def __init__(self, regexStr):
        self.re = re.compile(r'\A' + regexStr + r'\Z')
        self.raw_text = regexStr

    def __eq__(self, test):
        return self.re.match(test)

    def __repr__(self):
        return 'Regex(' + repr(self.raw_text) + ')'

## Functions
def TemplateContext(name, parent=None):
    ctx = Context()
    ctx.type = CT_TEMPLATE
    ctx.parent = parent
    ctx.name = name
    return ctx

def TypedefContext(name, parent=None):
    ctx = Context()
    ctx.type = CT_TYPEDEF
    ctx.parent = parent
    ctx.name = name
    return ctx

def StructContext(name, parent=None):
    ctx = Context()
    ctx.type = CT_STRUCT
    ctx.parent = parent
    ctx.name = name
    return ctx

def FieldContext(name, parent):
    assert(parent.type == CT_STRUCT)
    ctx = Context()
    ctx.type = CT_FIELD
    ctx.parent = parent
    ctx.name = name
    return ctx

def FunctionContext(name, stname='', parent=None):
    ctx = Context()
    ctx.type = CT_FUNCTION
    ctx.parent = parent
    ctx.name = name
    ctx.stname = stname
    return ctx

def ParamContext(name, parent, udtptr=False):
    assert(parent.type == CT_FUNCTION)
    ctx = Context()
    ctx.type = CT_PARAM
    ctx.parent = parent
    ctx.name = name
    ctx.udtptr = udtptr
    return ctx

def warnForUnusedRules():
    for ind, groups in Rules.items():
        ind_usage = RuleUsage[ind]
        for (cond, rules), rules_usage in zip(groups, ind_usage):
            for rule, used in zip(rules, rules_usage):
                if not used:
                    print("Unused rule: [%d][%s] %s" % (ind, repr(cond), repr(rule)))

def ruleMatches(rule, context):
    for matchValue in reversed(rule):
        if context is None or not (matchValue == context.name):
            return False
        context = context.parent
    return True

def getPointers(numPointers, valueType, context):
    ## Type-independent rules
    if numPointers == 1:
        if context.type == CT_TEMPLATE:
            return '*'
        if context.type == CT_PARAM and context.parent.stname and context.name == 'self':
            return '*'
        if context.type == CT_PARAM and context.name == 'pOut':
            return '*'
        if context.type == CT_PARAM and context.udtptr:
            return '*'

    ## Search for a matching rule
    rulesByDepth = Rules.get(numPointers)
    if rulesByDepth:
        for groupIdx, typeRules in enumerate(rulesByDepth):
            if typeRules[0] == valueType:
                for ruleIdx, rule in enumerate(typeRules[1]):
                    if ruleMatches(rule[0], context):
                        RuleUsage[numPointers][groupIdx][ruleIdx] = True
                        return rule[1]

    print("no matching pointer rules for", repr(context), '*' * numPointers + valueType)
    pointers = ''
    for i in range(numPointers):
        pointers += '[*c]'
    return pointers

## Data
# Context Types
CT_STRUCT = 1
CT_FIELD = 2
CT_FUNCTION = 3
CT_PARAM = 4
CT_TEMPLATE = 5
CT_TYPEDEF = 6

# Rules is a dictionary.  The first key is the number of indirections.  The second is the C value type.
# The value of that lookup is an array of rules.  Each rule is a tuple (match, zigPointerStr).  match is
# an array of comparisons to perform at each level, with the rightmost member of the array being the most
# specific.  So for example, ['format'] matches any field or parameter named 'format'.  ['Foo', 'format']
# would only match fields or params named 'format' in a struct or function named 'Foo'.
Rules = {
    1: [
        ("char", [
            (['ImGuiTextFilter_ImGuiTextFilter', 'default_filter'], '?[*:0]'),
            (['igInputTextWithHint', 'hint'], '?[*:0]'),
            (['igSetClipboardText', 'text'], '?[*:0]'),
            (['igBeginCombo', 'preview_value'], '?[*:0]'),
            (['igCombo_Str_arr', 'items'], '[*:0]'),
            (['igListBox_Str_arr', 'items'], '[*:0]'),
            (['igColumns', 'id'], '?[*:0]'),
            (['ImGuiTextBuffer_append', 'str'], '?[*]'),

            (['GetClipboardTextFn', '', 'return'], '?[*:0]'),
            (['SetClipboardTextFn', '', 'text'], '?[*:0]'),

            (['ImFont_CalcWordWrapPositionA', 'return'], '?[*]'),
            (['igSaveIniSettingsToMemory', 'return'], '?[*:0]'),
            (['ImGuiTextBuffer_begin', 'return'], '[*]'),
            (['ImGuiTextBuffer_end', 'return'], '[*]'),
            (['ImGuiTextBuffer_c_str', 'return'], '[*:0]'),
            (['igGetClipboardText', 'return'], '?[*:0]'),
            (['igGetVersion', 'return'], '?[*:0]'),

            ([EndsWith('Name'), 'return'], '?[*:0]'),

            (['type'], '?[*:0]'),

            (['compressed_font_data_base85'], '?[*]'),
            (['items_separated_by_zeros'], '?[*]'),
            (['text'], '?[*]'),
            (['fmt'], '?[*:0]'),
            (['prefix'], '?[*:0]'),
            (['shortcut'], '?[*:0]'),
            (['overlay'], '?[*:0]'),
            (['overlay_text'], '?[*:0]'),
            (['buf'], '?[*]'),
            (['Buf'], '?[*]'),

            ([EndsWith('id')], '?[*:0]'),
            ([EndsWith('label')], '?[*:0]'),
            ([EndsWith('str')], '?[*:0]'),
            ([Contains('format')], '?[*:0]'),
            ([Contains('name')], '?[*:0]'),
            ([Contains('Name')], '?[*:0]'),
            ([Contains('begin')], '?[*]'),
            ([Contains('end')], '?[*]'),
            ([EndsWith('data')], '?[*]'),
            ([EndsWith('FnStrPtr'), 'getter', '', 'return'], '?[*:0]'),

            (['ImGuiTextRange', Always()], '?[*]'),
            (['ImGuiTextRange_ImGuiTextRange_Str', Always()], '?[*]'),
        ]),
        (Always(), [
            ([Regex('ImGuiStorage_Get.*Ref'), 'return'], '?*')
        ]),
        ('float', [
            (['igColorPicker4', 'ref_col'], '?*const[4]'),
            ([Regex('out_[rgbhsv]')], '*'),
        ]),
        ('int', [
            (['out_bytes_per_pixel'], '?*'),
            (['current_item'], '?*'),
            (['igCheckboxFlags_IntPtr', 'flags'], '*'),
        ]),
        ('unsigned int', [
            (['igCheckboxFlags_UintPtr', 'flags'], '*'),
        ]),
        ('size_t', [
            (['igSaveIniSettingsToMemory', 'out_ini_size'], '?*'),
        ]),
        ('ImWchar', [
            (['ranges'], '?[*:0]'),
            (['return'], '?[*:0]'),
            (['glyph_ranges'], '?[*:0]'),
            (['GlyphRanges'], '?[*:0]'),
        ]),
        ('ImFontAtlas', [
            ([EndsWith('Atlas')], '?*'),
            ([EndsWith('atlas')], '?*'),
            (['ImGuiIO', 'Fonts'], '?*'),
        ]),
        ('ImVec2', [
            (['igIsMousePosValid', 'mouse_pos'], '?*'),
            (['points'], '?[*]'),
        ]),
        ('ImGuiTableColumnSortSpecs', [
            (['ImGuiTableSortSpecs', 'Specs'], '?[*]'),
        ]),
        ('ImGuiWindowClass', [
            (['window_class'], '?*'),
        ]),
        (StartsWith("Im"), [
            ([EndsWith('Ptr')], '?[*]'),
            (['igGetIO', 'return'], '*'),
            (['igGetDrawData', 'return'], '*'),
            ([Not(EndsWith('s'))], '?*'),
        ]),
        (Always(), [
            ([StartsWith('TexPixels')], '?[*]'),
            ([StartsWith('p_')], '?*'),
            ([StartsWith('v')], '*'),
            ([StartsWith('out_')], '*'),
        ]),
    ],
    2: [
        (Always(), [
            ([StartsWith('ImFontAtlas_GetTexData'), 'out_pixels'], '*?[*]'),
            (['ImFont_CalcTextSizeA', 'remaining'], '?*?[*:0]'),
        ]),
    ],
}

RuleUsage = {}
for ind, groups in Rules.items():
    ind_usage = []
    for cond, rules in groups:
        ind_usage.append([False] * len(rules))
    RuleUsage[ind] = ind_usage
### End Pointer Rules

### Begin Generate
## Types
Structure = namedtuple('Structure', ['zigName', 'fieldsDecl', 'functions'])

class ZigData:
    def __init__(self):
        self.opaqueTypes = {}
        """ {cName: True} """

        self.typedefs = {}
        """ {cName : zigDecl} """

        self.bitsets = []
        """ []zigDecl """

        self.enums = []
        """ []zigDecl """

        self.structures = {}
        """ {cName : Structure} """

        self.rawCommands = []
        """ []zigDecl """

        self.rootFunctions = []
        """ []zigDecl """

    def addTypedef(self, name, definition):
        # don't generate known type conversions
        if name in type_conversions: return

        if name in ('const_iterator', 'iterator', 'value_type'): return

        if definition.endswith(';'): definition = definition[:-1]

        # don't generate redundant C typedefs
        if definition == 'struct '+name:
            self.opaqueTypes[name] = True
            return

        decl = 'pub const '+self.convertTypeName(name)+' = '+self.convertComplexType(definition, TypedefContext(name))+';'
        self.typedefs[name] = decl

    def addFlags(self, name, jsonValues):
        self.typedefs.pop(name, None)

        if name == 'ImGuiCond':
            rawName = name
            zigRawName = 'Cond'
        else:
            assert(name.endswith('Flags'))
            rawName = name[:-len('Flags')]
            zigRawName = self.convertTypeName(rawName)
        zigFlagsName = zigRawName + 'Flags'

        # list of (name, int_value)
        aliases = []

        bits = [None] * 32
        for value in jsonValues:
            valueName = value['name'].replace(name + '_', '')
            intValue = value['calc_value']
            if intValue != 0 and (intValue & (intValue - 1)) == 0:
                bitIndex = -1;
                while (intValue):
                    intValue >>= 1
                    bitIndex += 1
                if bits[bitIndex] == None:
                    bits[bitIndex] = valueName
                else:
                    aliases.append((valueName, 1<<bitIndex))
            else:
                aliases.append((valueName, intValue))

        for i in range(32):
            if bits[i] is None:
                bits[i] = '__reserved_bit_%02d' % i

        decl = 'pub const '+zigFlagsName+'Int = FlagsInt;\n'
        decl += 'pub const '+zigFlagsName+' = packed struct {\n'
        for bitName in bits:
            decl += '    ' + bitName + ': bool = false,\n'
        if aliases:
            decl += '\n'
            for alias, intValue in aliases:
                values = [ '.' + bits[x] + '=true' for x in range(32) if (intValue & (1<<x)) != 0 ]
                if values:
                    init = '.{ ' + ', '.join(values) + ' }'
                else:
                    init = '.{}'
                decl += '    pub const ' + alias + ': @This() = ' + init + ';\n'
        decl += '\n    pub usingnamespace FlagsMixin(@This());\n'

        decl += '};'
        self.bitsets.append(decl)

    def addEnum(self, name, jsonValues):
        self.typedefs.pop(name, None)
        zigName = self.convertTypeName(name)
        sentinels = []
        decl = 'pub const '+zigName+' = enum (i32) {\n'
        for value in jsonValues:
            if value['name'] == 'ImGuiMod_None':
                continue

            valueName = value['name'].replace(name + '_', '')
            if valueName[0] >= '0' and valueName[0] <= '9':
                valueName = '@"' + valueName + '"'
            valueValue = str(value['value'])
            if name in valueValue:
                valueValue = valueValue.replace(name+'_', '@This().')
            if valueName == 'COUNT' or valueName.endswith('_BEGIN') or valueName.endswith('_OFFSET') or valueName.endswith('_END') or valueName.endswith('_COUNT') or valueName.endswith('_SIZE'):
                sentinels.append('    pub const '+valueName+' = '+valueValue+';')
            else:
                decl += '    '+valueName+' = '+valueValue+',\n'
        decl += '    _,\n'
        if sentinels:
            decl += '\n' + '\n'.join(sentinels) + '\n'
        decl += '};'
        self.enums.append(decl)

    def addStruct(self, name, jsonFields):
        self.opaqueTypes.pop(name, None)
        zigName = self.convertTypeName(name)
        decl = ''
        structContext = StructContext(name)
        for field in jsonFields:
            fieldName = field['name']
            buffers = []
            while (fieldName.endswith(']')):
                start = fieldName.rindex('[')
                bufferLen = fieldName[start+1:-1]
                fieldName = fieldName[:start]
                buffers.append(self.convertArrayLen(bufferLen))
            buffers.reverse()
            fieldType = field['type']
            templateType = field['template_type'] if 'template_type' in field else None
            zigType = self.convertComplexType(fieldType, FieldContext(fieldName, structContext))
            if len(fieldName) == 0:
                fieldName = 'value'
            decl += '    '+fieldName+': '
            for length in buffers:
                decl += '['+length+']'
            decl += zigType + ',\n'
        if decl: #strip trailing newline
            decl = decl[:-1]
        self.structures[name] = Structure(zigName, decl, [])

    def addFunction(self, name, jFunc):
        rawName = jFunc['ov_cimguiname']
        stname = jFunc['stname'] if 'stname' in jFunc else None
        if 'templated' in jFunc and jFunc['templated'] == True:
            pass
        else:
            self.makeFunction(jFunc, name, rawName, stname, self.structures)

    def addFunctionSet(self, jSet):
        byName = {}
        for func in jSet:
            if 'nonUDT' in func:
                if func['nonUDT'] == 1:
                    rootName = func['ov_cimguiname'].replace('_nonUDT', '')
                    byName[rootName] = func
            else:
                rootName = func['ov_cimguiname']
                if not (rootName in byName):
                    byName[rootName] = func

        for name, func in byName.items():
            self.addFunction(name, func);

    def makeFunction(self, jFunc, baseName, rawName, stname, parentTable):
        functionContext = FunctionContext(rawName, stname)
        if 'ret' in jFunc:
            retType = jFunc['ret']
        elif jFunc.get('constructor') == True:
            retType = stname
        else:
            retType = 'void'
        params = []
        isVarargs = False
        for arg in jFunc['argsT']:
            udtptr = 'udtptr' in arg and arg['udtptr']
            if arg['type'] == 'va_list':
                return # skip this function entirely
            if arg['type'] == '...':
                params.append(('...', '...', False))
                isVarargs = True
            else:
                argName = arg['name']
                argType = self.convertComplexType(arg['type'], ParamContext(argName, functionContext, udtptr))
                if argName == 'type':
                    argName = 'kind'
                params.append((argName, argType, udtptr))

        paramStrs = [ '...' if typeStr == '...' else (name + ': ' + typeStr) for name, typeStr, udtptr in params ]
        retType = self.convertComplexType(retType, ParamContext('return', functionContext))

        rawDecl = '    pub extern fn {}({}) callconv(.C) {};'.format(
            rawName,
            ', '.join(paramStrs),
            ('*' + retType) if jFunc.get('constructor') == True else retType
        )
        self.rawCommands.append(rawDecl)

        declName = self.makeZigFunctionName(jFunc, baseName, stname)

        wrappedName = declName
        needsWrap = False
        beforeCall = []
        wrappedRetType = retType
        returnExpr = None
        returnCapture = None

        defaultParamStrs = []
        defaultPassStrs = []
        hasDefaults = False

        paramStrs = []
        passStrs = []

        jDefaults = jFunc['defaults']

        if wrappedRetType.endswith('FlagsInt'):
            needsWrap = True
            wrappedRetType = wrappedRetType[:-len('Int')]
            returnCapture = '_retflags'
            returnExpr = wrappedRetType + '.fromInt(_retflags)'

        if 'nonUDT' in jFunc and jFunc['nonUDT'] == 1:
            assert(retType == 'void')
            needsWrap = True

            returnParam = params[0];
            params = params[1:]

            assert(returnParam[0] == 'pOut')
            wrappedRetType = returnParam[1]
            # strip one pointer
            assert(wrappedRetType[0] == '*')
            wrappedRetType = wrappedRetType[1:]

            beforeCall.append('var out: '+wrappedRetType+' = undefined;')
            passStrs.append('&out')
            returnExpr = 'out'

        for name, typeStr, udtptr in params:
            if name == 'type':
                name = 'kind'
            wrappedType = typeStr
            wrappedPass = name

            if typeStr.endswith('FlagsInt') and not ('*' in typeStr):
                needsWrap = True
                wrappedType = typeStr.replace('FlagsInt', 'Flags')
                wrappedPass = name + '.toInt()'
            elif udtptr:
                needsWrap = True
                wrappedType = typeStr[len('*const '):]
                wrappedPass = '&' + name

            paramStrs.append(name + ': ' + wrappedType)
            passStrs.append(wrappedPass)

            if name in jDefaults:
                hasDefaults = True
                defaultPassStrs.append(self.convertParamDefault(jDefaults[name], wrappedType, ParamContext(name, functionContext)))
            else:
                defaultParamStrs.append(paramStrs[-1])
                defaultPassStrs.append(name) # pass name not wrappedPass because we are calling the wrapper

        wrapper = []

        if not isVarargs and hasDefaults:
            defaultsName = wrappedName
            wrappedName += 'Ext'

        if not isVarargs and needsWrap:
            wrapper.append('pub inline fn '+wrappedName+'(' + ', '.join(paramStrs) + ') '+wrappedRetType+' {')
            for line in beforeCall:
                wrapper.append('    ' + line)
            callStr = 'raw.'+rawName+'('+', '.join(passStrs)+');'
            if returnExpr is None:
                wrapper.append('    return '+callStr)
            else:
                if returnCapture is None:
                    wrapper.append('    '+callStr)
                else:
                    wrapper.append('    const '+returnCapture+' = '+callStr)
                wrapper.append('    return '+returnExpr+';')
            wrapper.append('}')
        else:
            wrapper.append('/// '+wrappedName+'('+', '.join(paramStrs)+') '+wrappedRetType)
            wrapper.append('pub const '+wrappedName+' = raw.'+rawName+';')

        if not isVarargs and hasDefaults:
            wrapper.append('pub inline fn '+defaultsName+'('+', '.join(defaultParamStrs)+') '+wrappedRetType+' {')
            wrapper.append('    return @This().'+wrappedName+'('+', '.join(defaultPassStrs)+');')
            wrapper.append('}')


        if stname:
            wrapperStr = '    ' + '\n    '.join(wrapper);
            parentTable[stname].functions.append(wrapperStr)
        else:
            self.rootFunctions.append('\n'.join(wrapper))

    def makeZigFunctionName(self, jFunc, baseName, struct):
        if struct:
            declName = baseName.replace(struct+'_', '')
            if 'constructor' in jFunc:
                declName = 'init_' + declName
            elif 'destructor' in jFunc:
                declName = declName.replace('destroy', 'deinit')
        elif baseName in function_name_whitelist:
            return baseName
        else:
            assert(baseName[0:2] == 'ig')
            declName = baseName[2:]

        return declName

    def convertParamDefault(self, defaultStr, typeStr, context):
        if typeStr == 'f32':
            if defaultStr.endswith('f'):
                floatStr = defaultStr[:-1]
                if floatStr.startswith('+'):
                    floatStr = floatStr[1:]
                try:
                    floatValue = float(floatStr)
                    return floatStr
                except:
                    pass
            if defaultStr == 'FLT_MAX':
                return 'FLT_MAX'
            if defaultStr == '-FLT_MIN':
                return '-FLT_MIN'
            if defaultStr == '0':
                return '0'
            if defaultStr == '1':
                return '1'

        if typeStr == 'f64':
            try:
                floatValue = float(defaultStr)
                return defaultStr
            except:
                pass

        if typeStr == 'i32' or typeStr == 'u32' or typeStr == 'usize' or typeStr == 'ID':
            if defaultStr == "sizeof(float)":
                return '@sizeOf(f32)'
            try:
                intValue = int(defaultStr)
                return defaultStr
            except:
                pass

        if typeStr == 'bool':
            if defaultStr in ('true', 'false'):
                return defaultStr

        if typeStr in {'Vec2', '*Vec2', '*const Vec2'} and defaultStr.startswith('ImVec2('):
            params = defaultStr[defaultStr.index('(')+1 : defaultStr.index(')')]
            items = params.split(',')
            assert(len(items) == 2)
            return '.{.x='+self.convertParamDefault(items[0], 'f32', context) + \
                ',.y='+self.convertParamDefault(items[1], 'f32', context)+'}'

        if typeStr in {'Vec4', '*Vec4', '*const Vec4'} and defaultStr.startswith('ImVec4('):
            params = defaultStr[defaultStr.index('(')+1 : defaultStr.index(')')]
            items = params.split(',')
            assert(len(items) == 4)
            return '.{.x='+self.convertParamDefault(items[0], 'f32', context) + \
                ',.y='+self.convertParamDefault(items[1], 'f32', context) + \
                ',.z='+self.convertParamDefault(items[2], 'f32', context) + \
                ',.w='+self.convertParamDefault(items[3], 'f32', context)+'}'

        if defaultStr.startswith('"') and defaultStr.endswith('"'):
            return defaultStr
        if ((typeStr.startswith("?") or typeStr.startswith("[*c]") or typeStr.endswith("Callback"))
            and (defaultStr == '0' or defaultStr == 'NULL')):
            return 'null'
        if typeStr == 'MouseButton':
            if defaultStr == '0':
                return '.Left'
            if defaultStr == '1':
                return '.Right'
        if typeStr == 'PopupFlags' and defaultStr == '1':
            return '.{ .MouseButtonRight = true }'
        if typeStr.endswith("Flags") and not ('*' in typeStr):
            if defaultStr == "0":
                return '.{}'
            if defaultStr == 'ImDrawCornerFlags_All':
                return 'DrawCornerFlags.All'

        if typeStr == '?*anyopaque' and defaultStr == 'nullptr':
            return 'null'

        if defaultStr == '(((ImU32)(255)<<24)|((ImU32)(255)<<16)|((ImU32)(255)<<8)|((ImU32)(255)<<0))' and typeStr == 'u32':
            return '0xFFFFFFFF'
        print("Warning: Couldn't convert default value "+defaultStr+" of type "+typeStr+", "+repr(context))
        return defaultStr

    def convertComplexType(self, type, context):
        # remove trailing const, it doesn't mean anything to Zig
        if type.endswith('const'):
            type = type[:-5].strip()

        if type == 'ImDrawCallback' and context.name == 'UserCallback':
            return '?*anyopaque'

        pointers = ''
        arrays = ''
        arrayModifier = ''
        bufferNeedsPointer = False
        while type.endswith(']'):
            start = type.rindex('[')
            length = type[start + 1:-1].strip()
            type = type[:start].strip()
            if length == '':
                pointers += '[*]'
            else:
                bufferNeedsPointer = True
                arrays = '[' + self.convertArrayLen(length) + ']' + arrays
        if bufferNeedsPointer and context.type == CT_PARAM:
            pointers = '*' + pointers
        if type.endswith('const'):
            type = type[:-5].strip()
            arrayModifier = 'const'

        if type.startswith('union'):
            anonTypeContext = StructContext('', context)
            # anonymous union
            paramStart = type.index('{')+1
            paramEnd = type.rindex('}')-1
            params = [x.strip() for x in type[paramStart:paramEnd].split(';') if x.strip()]
            zigParams = []
            for p in params:
                if p == "...":
                    zigParams.append("...")
                else:
                    spaceIndex = p.rindex(' ')
                    paramName = p[spaceIndex+1:]
                    paramType = p[:spaceIndex]
                    zigParams.append(paramName + ': ' + self.convertComplexType(paramType, FieldContext(paramName, anonTypeContext)))
            return 'extern union { ' + ', '.join(zigParams) + ' }'

        if '(*)' in type:
            # function pointer
            index = type.index('(*)')
            returnType = type[:index]
            funcContext = FunctionContext('', '', context)
            zigReturnType = self.convertComplexType(returnType, ParamContext('return', funcContext))
            params = type[index+4:-1].split(',')
            zigParams = []
            for p in params:
                if p == "...":
                    zigParams.append("...")
                else:
                    spaceIndex = p.rindex(' ')
                    paramName = p[spaceIndex+1:]
                    paramType = p[:spaceIndex]
                    while paramName.startswith('*'):
                        paramType += '*'
                        paramName = paramName[1:].strip()
                    zigParams.append(paramName + ': ' + self.convertComplexType(paramType, ParamContext(paramName, funcContext)))
            return '?*fn ('+', '.join(zigParams)+') callconv(.C) '+zigReturnType

        valueConst = False
        if type.startswith('const'):
            valueConst = True
            type = type[6:]

        numPointers = 0
        while (type.endswith('*')):
            type = type[:-1]
            numPointers += 1

        valueType = type

        if valueType == 'void':
            if numPointers == 0: return 'void'
            else:
                if valueConst:
                    valueType = 'const void*'
                else:
                    valueType = 'void*'
                numPointers -= 1
                valueConst = False

        zigValue = pointers
        zigValue += arrayModifier

        if numPointers > 0:
            zigValue += getPointers(numPointers, valueType, context)

        if valueConst and not zigValue.endswith('const'):
            # Skip adding const for ImVec types
            if type in {'ImVec2', 'ImVec4'}:
                pass
            # Special case: ColorPicker4.ref_col is ?*const[4] f32
            # getPointers returns ?*const[4], don't put another const after that.
            elif not (context.name == 'ref_col' and context.parent.name == 'igColorPicker4'):
                zigValue += 'const'

        if numPointers > 0 and isFlags(valueType):
            if zigValue[-1].isalpha():
                zigValue += ' '
            zigValue += 'align(4) '

        zigValue += arrays

        if len(zigValue) > 0 and zigValue[-1].isalpha():
            zigValue += ' '

        innerType = self.convertTypeName(valueType)
        zigValue += innerType

        if numPointers == 0 and isFlags(valueType):
            if context.type == CT_PARAM:
                zigValue += 'Int'
            if context.type == CT_FIELD:
                zigValue += ' align(4)'

        return zigValue

    def convertArrayLen(self, length):
        try:
            int_val = int(length)
            return length
        except:
            pass

        if length.endswith('_COUNT'):
            bufferIndexEnum = length[:-len('_COUNT')]
            zigIndexEnum = self.convertTypeName(bufferIndexEnum)
            return zigIndexEnum + '.COUNT'

        if length == 'ImGuiKey_KeysData_SIZE':
            return 'Key.KeysData_SIZE'

        #print("Couldn't convert array size:", length)
        return length

    def convertTypeName(self, cName):
        if cName in type_conversions:
            return type_conversions[cName]
        elif cName.startswith('ImVector_'):
            rest = cName[len('ImVector_'):]
            prefix = 'Vector('
            if rest.endswith('Ptr'):
                rest = rest[:-len('Ptr')]
                prefix += '?*'
            return prefix + self.convertTypeName(rest) + ')'
        elif cName.startswith('ImGui'):
            return cName[len('ImGui'):]
        elif cName.startswith('Im'):
            return cName[len('Im'):]
        else:
            print("Couldn't convert type "+repr(cName))
            return cName

    def writeFile(self, f):
        with open(TEMPLATE_FILE) as template:
            f.write(template.read())

        for t in self.opaqueTypes:
            f.write('pub const '+self.convertTypeName(t)+' = opaque {};\n')

        for v in self.typedefs.values():
            f.write(v + '\n')
        f.write('\n')

        for b in self.bitsets:
            f.write(b + '\n\n')

        for e in self.enums:
            f.write(e + '\n\n')

        for s in self.structures.values():
            f.write('pub const '+s.zigName+' = extern struct {\n')
            f.write(s.fieldsDecl+'\n')
            if s.functions:
                for func in s.functions:
                    f.write('\n')
                    f.write(func+'\n')
            f.write('};\n\n')

        for func in self.rootFunctions:
            f.write('\n')
            f.write(func+'\n')
        f.write('\n')

        f.write('pub const raw = struct {\n')
        for r in self.rawCommands:
            f.write(r+'\n')
        f.write('};\n')

        if False:
            f.write(
                textwrap.dedent(
                    """
                    test "foo" {
                        var cb: DrawCallback = undefined;
                        const std = @import("std");
                        _ = std.meta.fields(@This());
                        _ = std.meta.fields(raw);
                        var vec: Vector(f32) = undefined;
                        vec.init();
                    }
                    """
                )
            )

## Functions
def isFlags(cName):
    return cName.endswith('Flags') or cName == 'ImGuiCond'

## Data
function_name_whitelist = { 'ImGuiFreeType_GetBuilderForFreeType', 'ImGuiFreeType_SetAllocatorFunctions' }
type_conversions = {
    'int': 'i32',
    'unsigned int': 'u32',
    'unsigned long long': 'u64',
    'short': 'i16',
    'unsigned short': 'u16',
    'float': 'f32',
    'double': 'f64',
    'void*': '?*anyopaque',
    'const void*': '?*const anyopaque',
    'bool': 'bool',
    'char': 'u8',
    'unsigned char': 'u8',
    'size_t': 'usize',
    'ImS8': 'i8',
    'ImS16': 'i16',
    'ImS32': 'i32',
    'ImS64': 'i64',
    'ImU8': 'u8',
    'ImU16': 'u16',
    'ImU32': 'u32',
    'ImU64': 'u64',
    'ImGuiCond': 'CondFlags',
    'FILE': 'anyopaque',
}
### End Generate

if __name__ == '__main__':
    # cimgui/generator/output/definitions.json
    COMMANDS_JSON_FILE = os.environ.get('COMMANDS_JSON_FILE')
    if COMMANDS_JSON_FILE is None:
        raise FileNotFoundError

    # cimgui/generator/output/definitions_impl.json
    IMPL_JSON_FILE = os.environ.get('IMPL_JSON_FILE')
    if IMPL_JSON_FILE is None:
        raise FileNotFoundError

    # src/generated/imgui.zig
    OUTPUT_PATH = os.environ.get('OUTPUT_PATH')
    if OUTPUT_PATH is None:
        raise FileNotFoundError

    # cimgui/generator/output/structs_and_enums.json
    STRUCT_JSON_FILE = os.environ.get('STRUCT_JSON_FILE')
    if STRUCT_JSON_FILE is None:
        raise FileNotFoundError

    # src/template.zig
    TEMPLATE_FILE = os.environ.get('TEMPLATE_FILE')
    if TEMPLATE_FILE is None:
        raise FileNotFoundError

    # cimgui/generator/output/typedefs_dict.json
    TYPEDEFS_JSON_FILE = os.environ.get('TYPEDEFS_JSON_FILE')
    if TYPEDEFS_JSON_FILE is None:
        raise FileNotFoundError

    with open(STRUCT_JSON_FILE) as f:
        jsonStructs = json.load(f)
    with open(TYPEDEFS_JSON_FILE) as f:
        jsonTypedefs = json.load(f)
    with open(COMMANDS_JSON_FILE) as f:
        jsonCommands = json.load(f)

    data = ZigData()

    for typedef in jsonTypedefs:
        data.addTypedef(typedef, jsonTypedefs[typedef])

    jsonEnums = jsonStructs['enums']
    for enumName in jsonEnums:
        # enum name in this data structure ends with _, so strip that.
        actualName = enumName
        if actualName.endswith('_'):
            actualName = actualName[:-1]
        if isFlags(actualName):
            data.addFlags(actualName, jsonEnums[enumName])
        else:
            data.addEnum(actualName, jsonEnums[enumName])

    jsonStructures = jsonStructs['structs']
    for structName in jsonStructures:
        data.addStruct(structName, jsonStructures[structName])

    for overrides in jsonCommands.values():
        data.addFunctionSet(overrides)

    # remove things that are manually defined in template.zig
    del data.structures['ImVec2']
    del data.structures['ImVec4']
    del data.structures['ImColor']
    del data.typedefs['ImTextureID']

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w+", newline='\n') as f:
        data.writeFile(f)

    warnForUnusedRules()
