grep -H "End of script.*CPU:" ../synth_InO/*.log |
sed -E 's#^([^:]+):.*CPU: user ([0-9.]+)s system ([0-9.]+)s, MEM: ([0-9.]+) MB.*#\1 \2 \3 \4#' |
awk '
{
    user += $2
    sys  += $3
    if ($4 > maxmem) maxmem = $4
    printf "%-45s  user=%8.2fs  sys=%6.2fs  mem=%8.2fMB\n",
           $1, $2, $3, $4
}
END {
    printf "\nTOTAL CPU : %.2f s = %.2f min\n", user+sys, (user+sys)/60
    printf "MEM max   : %.2f MB\n", maxmem
}'
