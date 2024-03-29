
if [ $# -lt 1 ]; then
    echo "usage: <outdir>"
    exit 1
fi

BASEDIR="$(realpath "`dirname "$0"`")"
cd "$BASEDIR"

OUTDIR="$1"
OUTSRC="$OUTDIR/bootstrap_data.cpp"
OUTHDR="$OUTDIR/bootstrap_data.h"

CXX="${CXX-c++} -I../../../include -I$OUTDIR/../.. -I$OUTDIR"
PYTHON3=${PYTHON3-python3}

echo \
'#ifndef CATALOG_SYSTABLES_BOOTSTRAP_DATA_H
#define CATALOG_SYSTABLES_BOOTSTRAP_DATA_H

/*!
 * @file
 * Some meta info about the bootstrap systable data.
 * This file is automatically generated, DO NOT modify.
 */

namespace taco {

constexpr const int num_bootstrap_tables = 4;' > "$OUTHDR"

# We run the preprocessor here in the script and inline the result so that
# Doxygen will generate a better documentation of the generated code.
echo \
'/*!
 * @file
 * Contents of the bootstrap systable data.
 * This file is automatically generated, DO NOT modify.
 */

#include "tdb.h"

#include "catalog/BootstrapCatCache.h"

namespace taco {

BootstrapCatCache::BootstrapCatCache():
    m_table{
'"$(echo '
#include "init_systable_gen.py.inc"

#define TABLEDEF "Table.inc"
#define TABLEDATA "Table.dat"
#include "load_table.py.inc"

bootstrap_tabnames = set(["Table", "Column", "Type", "Function"])
for d in datalist:
    if d["tabname"] in bootstrap_tabnames:
        print("BEGIN_BRACKET {}, {}, {}, {}, {}, \"{}\"}},".format(d["tabid"], d["tabissys"] and "true" or "false", d["tabisvarlen"] and "true" or "false", d["tabncols"], d["tabfid"], d["tabname"]))

' | ${CXX} -E - | ${PYTHON3}
    )"'
    },
    m_type{
'"$(echo "
#include \"init_systable_gen.py.inc\"

with open('$OUTHDR', 'a') as f:
    f.write('constexpr const int num_bootstrap_types = {};'.format(len(bootstrap_typnames)))
    f.write('\n')

for tname in bootstrap_typnames:
    t = typlist[typname2idx[tname]]
    print('BEGIN_BRACKET {}, {}, {}, {}, {}, \"{}\", {}, {}, {}'.format(
        t[typid], t[typlen], (t[typisvarlen] and 'true' or 'false'),
        (t[typbyref] and 'true' or 'false'),
        t[typalign], t[typname],
        t[typinfunc], t[typoutfunc], t[typlenfunc]) + \"},\")

" | ${CXX} -E - | ${PYTHON3} | grep '},$'
    )"'
    },
    m_column {
'"$(echo '
#include "init_systable_gen.py.inc"

def define_field(typparam, sqltype, colname):
    global TABLE_OID, COL_ID
    if sqltype < 0:
        is_array = True
        sqltype = -sqltype
    else:
        is_array = False
    print("BEGIN_BRACKET",
          "{},".format(TABLE_OID),
          "{},".format(COL_ID),
          (is_array and "true" or "false") + ",",
		  "false,",
          "{},".format(sqltype),
		  "{},".format(typparam),
		  "\"{}\"".format(colname) + "},")
    COL_ID += 1


#define DEFINE_SYSTABLE(_1, oid, ...) \
TABLE_OID, COL_ID = oid, 0
#define DEFINE_SYSTABLE_FIELD(sqltype, colname, ...) \
define_field(CONCAT(X_, sqltype), sqltype, STRINGIFY(colname))
#define DEFINE_SYSTABLE_FIELD_OPT(sqltype, colname, ...) \
define_field(CONCAT(X_, sqltype), sqltype, STRINGIFY(colname))

#define DEFINE_SYSTABLE_INDEX(...)

#include "Column.inc"
#include "Table.inc"
#include "Type.inc"
#include "Function.inc"

' | ${CXX} -E - | ${PYTHON3}
    )"'
    },
    m_function {
'"$(echo "
#include \"init_systable_gen.py.inc\"

funcid_set = set()
for tname in bootstrap_typnames:
    t = typlist[typname2idx[tname]]
    funcid_set.add(t[typinfunc])
    funcid_set.add(t[typoutfunc])
    funcid_set.add(t[typlenfunc])

if 0 in funcid_set:
    funcid_set.remove(0)

with open('$OUTHDR', 'a') as f:
    f.write('constexpr const int num_bootstrap_functions = {};'.format(len(funcid_set)))
    f.write('\n')

#define TABLEDEF \"Function.inc\"
#define TABLEDATA \"Function.dat\"
#include \"load_table.py.inc\"

for t in datalist:
    if t[funcid] in funcid_set:
        print('BEGIN_BRACKET {}, {}, {}, \"{}\"'.format(t[funcid], t[funcnargs], t[funcrettypid], t[funcname]) + '},')
" | ${CXX} -E - | ${PYTHON3} | grep '},$'
    )"'

    }
    {}

}
' | sed 's/^BEGIN_BRACKET /        {/' > "$OUTSRC"



NUM_COLS=`cat Column.inc Type.inc Table.inc Function.inc |
    grep '^DEFINE_SYSTABLE_FIELD' | wc -l`
echo \
'constexpr const int num_bootstrap_columns = '"${NUM_COLS}"';

}   // namespace taco

#endif  // CATALOG_SYSTABLES_BOOTSTRAP_DATA_H
' >> "$OUTHDR"


