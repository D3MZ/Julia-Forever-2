# SQL vocabulary ported from highlight.js 10.7.3 (BSD-3-Clause). See licenses/highlight-js-LICENSE.
# Source language SQL: bf56c9b66bea17ebfb891fb59fa165328468f79d03a60ecbed068c6cad351590
const SESSION_SQL_KEYWORDS=Set(split("all allocate alter and any are array array_max_cardinality as asensitive asymmetric at atomic authorization begin begin_frame begin_partition between bigint binary blob boolean both by call called cardinality cascaded case char char_length character character_length check classifier clob close collate collect column commit condition connect constraint contains convert copy corresponding create cross cube current current_catalog current_date current_default_transform_group current_path current_role current_row current_schema current_time current_timestamp current_path current_role current_transform_group_for_type current_user cursor cycle date day deallocate dec decimal decfloat declare default define delete describe deterministic disconnect distinct double drop dynamic each else empty end end_frame end_partition end-exec equals escape every except exec execute exists external false fetch filter float for foreign frame_row free from full function fusion get global grant group grouping groups having hold hour identity in indicator initial inner inout insensitive insert int integer intersect intersection interval into is join language large lateral leading left like like_regex local localtime localtimestamp match match_number match_recognize matches member merge method minute modifies module month multiset national natural nchar nclob new no none normalize not null numeric octet_length occurrences_regex of offset old omit on one only open or order out outer over overlaps overlay parameter partition pattern per percent period portion precedes precision prepare primary procedure ptf range reads real recursive ref references referencing release result return returns revoke right rollback rollup row rows running savepoint scope scroll search second seek select sensitive session_user set show similar skip smallint some specific specifictype sql sqlexception sqlstate sqlwarning start static submultiset subset succeeds symmetric system system_time system_user table tablesample then time timestamp timezone_hour timezone_minute to trailing translation trigger true truncate uescape union unique unknown update    user using value values varbinary varchar varying versioning when whenever where window with within without year add asc collation desc final first last view"))
const SESSION_SQL_LITERALS=Set(split("true false unknown"))
const SESSION_SQL_TYPES=Set(split("bigint binary blob boolean char character clob date dec decfloat decimal float int integer interval nchar nclob national numeric real row smallint time timestamp varchar varying varbinary"))
const SESSION_SQL_BUILTINS=Set(split("current_catalog current_date current_default_transform_group current_path current_role current_schema current_transform_group_for_type current_user session_user system_time system_user current_time localtime current_timestamp localtimestamp"))
const SESSION_SQL_FUNCTIONS=Set(split("abs acos array_agg asin atan avg cast ceil ceiling coalesce corr cos cosh count covar_pop covar_samp cume_dist dense_rank deref element exp extract first_value floor json_array json_arrayagg json_exists json_object json_objectagg json_query json_table json_table_primitive json_value lag last_value lead listagg ln log log10 lower max min mod nth_value ntile nullif percent_rank percentile_cont percentile_disc position position_regex power rank regr_avgx regr_avgy regr_count regr_intercept regr_r2 regr_slope regr_sxx regr_sxy regr_syy row_number sin sinh sqrt stddev_pop stddev_samp substring substring_regex sum tan tanh translate translate_regex treat trim trim_array unnest upper value_of var_pop var_samp width_bucket"))

"""Classify real SQL words using case-insensitive reserved and call-context vocabularies."""
function session_sql_word_kind(word::String,text::String,following::Int)
    lower=lowercase(word)
    if lower in SESSION_SQL_LITERALS
        :number
    elseif lower in SESSION_SQL_TYPES
        :type
    elseif lower in SESSION_SQL_BUILTINS || lower in SESSION_SQL_FUNCTIONS && occursin(r"^\s*\(",SubString(text,following))
        :type
    elseif lower in SESSION_SQL_KEYWORDS
        :keyword
    else
        :default
    end
end
