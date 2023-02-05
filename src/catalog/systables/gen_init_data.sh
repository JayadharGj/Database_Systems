if [ $# -lt 1 ]; then
    echo "usage: <outdir>"
    exit 1
fi

BASEDIR="$(realpath "`dirname "$0"`")"
cd "$BASEDIR"

OUTDIR="$1"

CXX="${CXX-c++} -I../../../include -I$OUTDIR/../.. -I$OUTDIR"
PYTHON3=${PYTHON3-python3}

FILE_LIST=`find . -name '*.inc' | grep -v '\.py\.inc' | sed 's,^./,,'`

# generate Table.dat
echo "generating Table.dat"
T=`mktemp`
echo \
'_COMMENT Data file for all system catalog tables.
_COMMENT This file is automatically generated, do NOT modify.
_EMPTYLINE

' > $T
for f in $FILE_LIST; do
echo "
#define INCLUDE_MACROS_ONLY
#include \"config.h\"
#include \"utils/misc.h\"

#ifdef ALWAYS_USE_FIXEDLEN_DATAPAGE
#define TABISVARLEN_VAL false
#else
#define TABISVARLEN_VAL true
#endif

#define DEFINE_SYSTABLE(name, oid, tabledesc) \
    { tabid: oid, tabissys: true, tabisvarlen: TABISVARLEN_VAL, \
      tabncols: $(grep '^DEFINE_SYSTABLE_FIELD' $f | wc -l), \
      tabfid: 0, tabname: STRINGIFY(name)},
#define DEFINE_SYSTABLE_FIELD(...)
#define DEFINE_SYSTABLE_FIELD_OPT(...)
#define DEFINE_SYSTABLE_INDEX(...)
" | cat - $f | ${CXX} -E -
done >> $T
grep '^\(_\|{\)' $T | \
    sed -e 's/_COMMENT/\/\//' -e 's/_EMPTYLINE//' > "${OUTDIR}/Table.dat"
rm -f $T

echo "generating CatCacheBase_gen.cpp"
echo '
#include "catalog/CatCacheBase.h"
#include "catalog/systables.h"

namespace taco {

std::shared_ptr<void>
CatCacheInternalAccess::CreateSysTableStruct(Oid tabid, const std::vector<Datum> &data) {
    void *systable_struct;
    switch (tabid) {
'"$(echo \
'
#include "init_systable_gen.py.inc"
#define TABLEDEF "Table.inc"
#define TABLEDATA "Table.dat"
#include "load_table.py.inc"

for d in datalist:
    print("    case {}:".format(d["tabid"]))
    print("        systable_struct = (void*) SysTable_{}::Create(data);".format(d["tabname"]))
    print("        return std::shared_ptr<void>(std::shared_ptr<SysTable_{}>((SysTable_{}*) systable_struct), systable_struct);".format(d["tabname"], d["tabname"]))
    print("        break;")
    print()

' | ${CXX} -E - | ${PYTHON3}
)"'
    }

    ASSERT(false, "unknown systable tabid " OID_FORMAT, tabid);
    return nullptr;
}

}   // namespace taco
' > "${OUTDIR}/CatCacheBase_gen.cpp"

# generate Column.dat
echo "generating Column.dat"
echo '
#include "init_systable_gen.py.inc"

print("// Data file for the Column system catalog table")
print("// This file is automatically generated. Do NOT modify.")
print()

def define_field(typparam, sqltype, colname):
    global TABLE_OID, COL_ID
    if sqltype < 0:
        is_array = True
        sqltype = -sqltype
    else:
        is_array = False
    print("{" + ("coltabid: {}, colid: {}, colisarray: {}, colisnullable: {},\n" + 
           " coltypid: {}, coltypparam: {}, colname: \"{}\"").format(
            TABLE_OID, COL_ID, (is_array and "true" or "false"), "false",
            sqltype, typparam, colname) + "},")
    COL_ID += 1

#define DEFINE_SYSTABLE(_1, oid, ...) \
TABLE_OID, COL_ID = oid, 0
#define DEFINE_SYSTABLE_FIELD(sqltype, colname, ...) \
define_field(CONCAT(X_, sqltype), sqltype, STRINGIFY(colname))
#define DEFINE_SYSTABLE_FIELD_OPT(sqltype, colname, ...) \
define_field(CONCAT(X_, sqltype), sqltype, STRINGIFY(colname))

#define DEFINE_SYSTABLE_INDEX(...)

' | cat - $FILE_LIST | ${CXX} -E - | ${PYTHON3} \
    > "${OUTDIR}/Column.dat"

echo "generating Index.dat and IndexColumn.dat"
echo "
#define INCLUDE_MACROS_ONLY
#define OPTYPE_CONSTANT_ONLY
#include \"config.h\"
#include \"utils/misc.h\"
#include \"utils/macro_map.h\"
#include \"expr/optypes.h\"

#include \"init_systable_gen.py.inc\"

#define TABLEDEF \"Table.inc\"
#define TABLEDATA \"Table.dat\"
#include \"load_table.py.inc\"
tab_datalist = datalist
tabname2tabid = {}
for t in tab_datalist:
    tabname2tabid[t[tabname]] = t[tabid]

#define TABLEDEF \"Column.inc\"
#define TABLEDATA \"Column.dat\"
#include \"load_table.py.inc\"
col_datalist = datalist
tabid_colname2colid = {}
tabid_colname2colinfo= {}
for t in col_datalist:
    tabid_colname2colid[(t[coltabid], t[colname])] = t[colid]
    tabid_colname2colinfo[(t[coltabid], t[colname])] = t

#define TABLEDEF \"Operator.inc\"
#define TABLEDATA \"Operator.dat\"
#include \"load_table.py.inc\"
op_datalist = datalist
eq_lookup = {}
lt_lookup = {}
for t in op_datalist:
    if t[optype] == OPTYPE_EQ and t[oparg0typid] == t[oparg1typid]:
        eq_lookup[t[oparg0typid]] = t[opfuncid]
    if t[optype] == OPTYPE_LT and t[oparg0typid] == t[oparg1typid]:
        lt_lookup[t[oparg0typid]] = t[opfuncid]

#define TABLEDEF \"Function.inc\"
#define TABLEDATA \"Function.dat\"
#include \"load_table.py.inc\"
func_datalist = datalist
nfound = 0
for f in func_datalist:
    if f[funcname] == 'VARCHAR_eq_ci':
        eq_lookup[VARCHAR(0)] = f[funcid]
        nfound += 1
    elif f[funcname] == 'VARCHAR_lt_ci':
        lt_lookup[VARCHAR(0)] = f[funcid]
        nfound += 1
if nfound < 2:
    print('case insensitive string comparison functions not found', file=sys.stderr)

#define DEFINE_SYSTABLE_INDEX(tabname, isunique, ...) {\
    'idxtabname': STRINGIFY(tabname), \
    'idxunique': isunique, \
    'idxtabcolnames': [MAP_LIST(STRINGIFY, __VA_ARGS__)] \
},

print('// Data file for the Index catalog')
print('// This is a file to be included into a python file using a C/C++')
print('// preprocessor.')
print('// This file is automatically generated, do NOT modify.')

idxcolout = open('""${OUTDIR}""/IndexColumn.dat', 'w')
idxcolout.write('// Data file for the IndexColumn catalog\n')
idxcolout.write('// This is a file to be included into a python file using a C/C++\n')
idxcolout.write('// preprocessor.')
idxcolout.write('// This file is automatically generated, do NOT modify.')


idx_list = [
$(cat $FILE_LIST | grep "^DEFINE_SYSTABLE_INDEX")
]

def create_idxname(tabname, idxtabcolnames):
    return tabname + '_' + '_'.join(idxtabcolnames)

// move the two indexes Index_idxid and IndexColumn_idxcoidxid_idxcolid to
// the first two. These are going to be looked up first using heap scans
// during the index initialization.
def idx_sort_key(i):
    if i['idxtabname'] == 'Index' and len(i['idxtabcolnames']) == 1 and i['idxtabcolnames'][0] == 'idxid':
        return (0, '')
    elif i['idxtabname'] == 'IndexColumn' and len(i['idxtabcolnames']) == 2 and i['idxtabcolnames'][0] == 'idxcolidxid' and i['idxtabcolnames'][1] == 'idxcolid':
        return (1, '')
    else:
        return (2, create_idxname(i['idxtabname'], i['idxtabcolnames']))
idx_list = sorted(idx_list, key=idx_sort_key)

// XXX(zy) we now hardcode the first idxid here assuming it won't clash with others
idxid = 1500
for idx in idx_list:
    idxtabname = idx['idxtabname']
    idxtabcolnames = idx['idxtabcolnames']
    idxncols = len(idxtabcolnames)
    idxtabid = tabname2tabid[idxtabname]
    idxname = create_idxname(idxtabname, idxtabcolnames)
    idxtabcolids = list(map(lambda colname: tabid_colname2colid[(idxtabid, colname)], idxtabcolnames))
    idxunique = idx['idxunique']

    // we set idxtyp to IDXTYP_INVALID(0) here so that the catalog cache
    // decide which type of index to build, depending on the test target
    // The idxcoleqfuncid and idxcolltfuncid are also left for the catalog cache to fill in.
    print('\n{{\n    idxid: {}, idxtabid: {}, idxtyp: 0, idxfid: 0, idxunique: {}, idxncols: {},\n    idxname: \"{}\"\n}},'.format(
        idxid, idxtabid, idxunique and 'True' or 'False', idxncols, idxname))
    for idxcolid in range(idxncols):
        idxcolinfo = tabid_colname2colinfo[(idxtabid, idxtabcolnames[idxcolid])]
        idxcoltypid = idxcolinfo[coltypid]
        idxcolisnullable = idxcolinfo[colisnullable]
        idxcoltypparam = idxcolinfo[coltypparam]
        idxcoleqfuncid = eq_lookup[idxcoltypid]
        idxcolltfuncid = lt_lookup[idxcoltypid]
        idxcolout.write('\n{{\n    idxcolidxid: {}, idxcolid: {}, idxcoltabcolid: {},\n    idxcoleqfuncid: {}, idxcolltfuncid: {}, idxcoltypid: {},\n    idxcolisnullable: {}, idxcoltypparam: {}\n}},\n'.format(
        idxid, idxcolid, idxtabcolids[idxcolid], idxcoleqfuncid, idxcolltfuncid,
        idxcoltypid, idxcolisnullable, idxcoltypparam))
    idxid += 1
idxcolout.close()
" | ${CXX} -E - | ${PYTHON3} \
    > "${OUTDIR}/Index.dat"
[ $? -ne 0 ] && exit $?

# generate Aggregation.dat
echo "generating Aggregation.dat"
echo \
'
#include "init_systable_gen.py.inc"
import sys

fmap = {}
farg1map = {}

#define TABLEDEF "Function.inc"
#define TABLEDATA "Function.dat"
#include "load_table.py.inc"

flist = datalist
for f in flist:
    fmap[f[funcid]] = f[funcrettypid]

#define TABLEDEF "FunctionArgs.inc"
#define TABLEDATA "FunctionArgs.dat"
#include "load_table.py.inc"

farglist = datalist
for farg in farglist:
    if farg[funcargid] == 1:
        farg1map[farg[funcid]] = farg[funcargtypid]

#define TABLEDEF "Aggregation.inc"
#define TABLEDATA "AggregationData.dat"
#include "load_table.py.inc"

#include "catalog/aggtyp.h"
OTHER=AGGTYPE(OTHER)
aggname2aggtid = {
    "COUNT": AGGTYPE(COUNT),
    "SUM": AGGTYPE(SUM),
    "MIN": AGGTYPE(MIN),
    "MAX": AGGTYPE(MAX),
    "AVG": AGGTYPE(AVG)
}

print("// Data file for the Aggregation catalog")
print("// This is a file to be included into a python file using a C/C++")
print("// preprocessor.")
print("// This file is automatically generated, do NOT modify.")
print()

nextoid = 1600
for agg in datalist:
    aggid = nextoid
    nextoid += 1
    if agg[aggaccfuncid] not in farg1map:
        sys.stderr.write("[ERROR] function {} not found".format(agg[aggaccfuncid]))
        sys.exit(1)
    aggoprtypid = farg1map[agg[aggaccfuncid]]
    if agg[aggfinalizefuncid] not in fmap:
        sys.stderr.write("[ERROR] function {} not found".format(agg[aggfinalizefuncid]))
        sys.exit(1)
    aggrettypid = fmap[agg[aggfinalizefuncid]]
    if agg[aggname] in aggname2aggtid:
        aggtid = aggname2aggtid[agg[aggname]]
    else:
        aggtid = OTHER
    print("{")
    print("    aggid: {}, aggtid: {}, aggoprtypid: {}, aggrettypid: {}, agginitfuncid: {},".format(
        aggid, aggtid, aggoprtypid, aggrettypid, agg[agginitfuncid]))
    print("    aggaccfuncid: {}, aggfinalizefuncid: {}, aggname: \"{}\"".format(
        agg[aggaccfuncid], agg[aggfinalizefuncid], agg[aggname]))
    print("},\n")
' | ${CXX} -E - | ${PYTHON3} - \
    > "${OUTDIR}/Aggregation.dat"

# generate init.dat and initoids.h
echo "generating init.dat and initoids.h"
echo \
'/*!
* @file The predefined OIDs for all systable Type and Table rows.
*/
#ifndef CATALOG_SYSTABLE_INITOIDS_H
#define CATALOG_SYSTABLE_INITOIDS_H

namespace taco {
namespace initoids {
' > "${OUTDIR}/initoids.h"
for incfile in $FILE_LIST; do
tablename="`echo "$incfile" | sed 's/\.inc$//'`"
echo \
'
#include "init_systable_gen.py.inc"

#define TABLEDEF "'${tablename}.inc'"
#define TABLEDATA "'${tablename}.dat'"
#include "load_table.py.inc"

decl_str = "table {}".format(tabid_)
for i in range(len(fields)):
    decl_str = decl_str + " {} {}".format(field_typids[i], field_typparams[i])
print(decl_str)

if tabname_ == "Table" or tabname_ == "Type" or tabname_ == "Function" or tabname_ == "Index":
    if tabname_ == "Function":
        tabprefix = "FUNC"
    elif tabname_ == "Index":
        tabprefix = "IDX"
    else:
        tabprefix  = tabname_[:3].upper()
    idcol = tabprefix.lower() + "id"
    namecol = tabprefix.lower() + "name"
    f = open("'"${OUTDIR}/initoids.h"'", "a")
else:
    f = None

for d in datalist:
    data_str = "data"
    if f is not None:
        f.write("constexpr const Oid {}_{} = {};\n".format(tabprefix, d[namecol], d[idcol]))
    for i in range(len(fields)):
        v = d[fields[i]]
        if field_typids[i] == BOOL:
            if v:
                data_str += " t"
            else:
                data_str += " f"
        elif field_typids[i] == VARCHAR_oid:
            data_str += " \"" + v + "\""
        else:
            data_str += " {}".format(v)
    print(data_str)

if f is not None:
    f.close()
' | ${CXX} -E - | ${PYTHON3} -

done > "${OUTDIR}/init.dat"
echo \
'}    // namespace initoids
}    // namespace taco
#endif        //CATALOG_SYSTABLE_INITOIDS_H
' >> "${OUTDIR}/initoids.h"
