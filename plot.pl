#!/usr/bin/perl -w

use strict;
use Getopt::Std;

my %opt=();
getopts("c:vDw:ClaPtT:HS:q:o:Lhm", \%opt);

if ($opt{h}) {
	print qq~Usage: plot [options] -c <column-names> [input-file]
Options:
    -q <separator> - separator char (defaults to comma)
    <column-names> - comma-separated list of columns
    -C             - cumulative
    -l             - list all values (x = row index)
    -a             - autoscale multiple curves
    -T <title>     - show title text
    -H             - plot histogram
    -P             - plot price (candlesticks) - requires 5 columns
    -o <file>      - save image in a file with the specified name
    -L             - show text labels next to values (y-values should have format <value>[\~<label>]
    -S ...         - calculate statistics:
       n                - count
       m                - mean
       s                - sdev
       p                - sharpe ratio
       d                - drawdown
    -D             - don't check for and don't skip duplicate header lines
    -w <style>     - line style:
       points           - with points
       lines            - with lines
       steps            - with steps
       impulses         - with steps
    -v             - verbose print
    -m             - enable use of mouse to zoom
    -t             - treat first column column as time
qq~;
	exit;
}

my $fname = shift @ARGV;
my $fh;
if ($fname) {
	open $fh, "<:encoding(utf8)", $fname or die $fname.": $!";
}
else {
	$fh = *STDIN;
}

$opt{w} = "steps" if !$opt{w};
$opt{w} = "candlesticks" if $opt{P};  # prices

die "Unsupported line style: $opt{w}" if ($opt{w} ne "points" && $opt{w} ne "lines" && $opt{w} ne "steps" && $opt{w} ne "candlesticks" && $opt{w} ne "impulses" && $opt{w} ne "boxes");

my $header = <$fh>; chomp $header;
if (!$opt{q}) {
	my @c_p = split(/\|/, $header);
	my @c_c = split(/,/, $header);
	$opt{q} = ($#c_p == 0 && $#c_c == 0)? '\b\s+': ($#c_p > $#c_c)? '\|': ',';
}
my $pattern = "$opt{q}";
my @columns = split(/$pattern/, $header);

print "Available columns:\n".join("\n", map {$_."\t".$columns[$_]} (0..$#columns))."\n" and exit if !$opt{c};

my @user_columns;
my %print_columns;

for ($opt{c} ? split(/,/, $opt{c}) : split(/$pattern/, $header)) {
	if (/^(\d+)-(\d+)$/) {
		$1 < $2 or die "Invalid column range: $_";
		push @user_columns, ($1..$2);
	}
	else {
		push @user_columns, $_;
	}
}

my @select_idx;
my @totals;
my @totals2;
my @drawdown;
my @drawdown_start_value;
my @last_drawdown;
my @n_drawdown;
my @last_n_drawdown;
my @counts;
my @min;
my @max;
my $col_name;

for my $print_col_name (@user_columns) {
	my $idx = 0;
	for $col_name (@columns) {
		if ($col_name eq $print_col_name || $idx eq $print_col_name) {  # index or name
			$print_columns{$col_name} = $idx;
			push @select_idx, $idx;
			push @totals, 0;
			push @totals2, 0;
			push @drawdown, 0;
			push @drawdown_start_value, 0;
			push @last_drawdown, 0;
			push @n_drawdown, 0;
			push @last_n_drawdown, 0;
			push @counts, 0;
			push @min, 0;
			push @max, 0;
			last;
		}
		$idx++;
	}
	die "unknown column $print_col_name, available: ". join(',', @columns) if ($#columns + 1 == $idx);
}

my $username = getpwuid( $< );
open TEMP, "> /tmp/plot.tmp.$username.$$.dat" or die "cannot open tmp file: $!\n";

my $timefmt = $opt{t} || ($columns[$select_idx[0]] =~ m /time|date|start|dt|\d\d:\d\d|\d{6}\.\d|201[2-9][01][0-9][0-3][0-9]/i)? 1: 0;
my $autodetect_time = $timefmt? 1: 0;
my $opt_C = $opt{C}? 1: 0;
my $opt_S = $opt{S}? 1: 0;
my $opt_l = $opt{l}? 1: 0;
my $opt_L = $opt{L}? 1: 0;
my $opt_a = $opt{a}? 1: 0;
my $labels;

while ( <$fh> ) {
	chomp;
	s/^\s+//;
    my @fields = split (/$pattern/);
	if (!$opt{D} && $fields[1] eq $columns[1]) {
		print STDERR "skipping $_\n" if $opt{v};
		next;
	}
	if ($opt_C || $opt_S || $opt_a) {
		for my $i (0..$#select_idx) {
			$i || $opt_l || next;
			my $idx = $select_idx[$i];
			if (defined($fields[$idx]) && $fields[$idx] ne "nan" && $fields[$idx] ne "") {
				$totals2[$i] += $fields[$idx] * $fields[$idx] if ($opt_S);
				$fields[$idx] += $totals[$i] if $opt_C;
				$totals[$i] = $opt_C ? $fields[$idx] : $fields[$idx] + $totals[$i];
				$counts[$i]++ if ($opt_S);
				$min[$i] = $fields[$idx] if ($opt_a && $fields[$idx] < $min[$i]);
				$max[$i] = $fields[$idx] if ($opt_a && $fields[$idx] > $max[$i]);
				if ($opt_S)	{
					if (1 == $counts[$i]) {
						$drawdown_start_value[$i] = $totals[$i];
					}
					if ($totals[$i] > $drawdown_start_value[$i]) {
						$drawdown_start_value[$i] = $totals[$i];
						$last_drawdown[$i] = 0;
						$last_n_drawdown[$i] = 0;
					}
					else {
						$last_drawdown[$i] = $totals[$i] - $drawdown_start_value[$i];
						$last_n_drawdown[$i] ++;
						if ($last_drawdown[$i] < $drawdown[$i])	{
							$drawdown[$i] = $last_drawdown[$i];
							$n_drawdown[$i] = $last_n_drawdown[$i];
						}
					}
				}
			}
		}
	}
    my @select_fields = map { (defined($fields[$_]) && $fields[$_] ne "nan")? $fields[$_]: "?" } @select_idx;
    if ($autodetect_time) {
		if ($fields[$select_idx[0]] =~ m/^\d\d:\d\d:\d\d(\.\d+)?$/) {
			$timefmt = "%H:%M:%S";
			$autodetect_time = 0;
		}
		elsif ($fields[$select_idx[0]] =~ m/^\d\d:\d\d$/) {
			$timefmt = "%H:%M";
			$autodetect_time = 0;
		}
		elsif ($fields[$select_idx[0]] =~ m/^\d{8}-\d\d:\d\d:\d\d(\.\d+)?$/) {
			$timefmt = "%Y%m%d-%H:%M:%S";
			$autodetect_time = 0;
		}
		elsif ($fields[$select_idx[0]] =~ m/^\d{8} \d\d:\d\d:\d\d(\.\d+)?$/) {
			$timefmt = "%Y%m%d_%H:%M:%S";
			$autodetect_time = 0;
		}
		elsif ($fields[$select_idx[0]] =~ m/^\d{8}:\d{6}\b/) {
			$timefmt = "%Y%m%d:%H%M%S";
			$autodetect_time = 0;
		}
		elsif ($fields[$select_idx[0]] =~ m/^\d{8}T\d{6}\b/) {
			$timefmt = "%Y%m%d_%H%M%S";
			$autodetect_time = 0;
		}
		elsif ($fields[$select_idx[0]] =~ m/^\d{4}-\d\d-\d\d([ T]\d\d:\d\d:\d\d(\.\d+)?)?\b/) {
			$timefmt = "%Y-%m-%d";
			$timefmt .= "_%H:%M:%S" if ($1);
			$autodetect_time = 0;
		}
		elsif ($fields[$select_idx[0]] =~ m/^\d{4}-\w{3}-\d\d[ T]\d\d:\d\d:\d\d\b/) {
			$timefmt = "%Y-%b-%d_%H:%M:%S";
			$autodetect_time = 0;
		}
		elsif ($fields[$select_idx[0]] =~ m/^\d{19}\b/) {
			$timefmt = "%s";
			$autodetect_time = 0;
		}
		elsif ($fields[$select_idx[0]] =~ m/^\d{8}\b/) {
			$timefmt = "%Y%m%d";
			$autodetect_time = 0;
		}
		elsif ($fields[$select_idx[0]] =~ m/^\d\d?\/\d?\d\/\d{4}\b/) {
			$timefmt = "%m/%d/%Y";
			$autodetect_time = 0;
		}
    }
	next if (0 == $#select_idx && $select_fields[0] eq "");
	$select_fields[0] =~ s/\.\d+$// if $timefmt;  # strip off msecs
	$select_fields[0] =~ s/[ T]/_/ if $timefmt;
	$select_fields[0] = substr($select_fields[0], 0, 10) if $timefmt eq '%s';
	if ($opt_L) {
		my $x = $select_fields[0];
		for my $i (1..$#select_idx) {
			my ($y, $label) = split (/~/, $select_fields[$i]);
			if (defined($label)) {
				$labels .= "set label \"$label\" at \"$x\",$y right front tc ls 0\n";
			}
		}
	}
    print TEMP join(' ', @select_fields)."\n";
}

print "Selected columns:\n";

for my $i (0..$#select_idx) {
	print $select_idx[$i]."\t".$columns[$select_idx[$i]];
	if ($counts[$i]) {
		my $sdev = sqrt( ($totals2[$i]  - $totals[$i] * $totals[$i] / $counts[$i]) / $counts[$i]);
		printf "\tmean=%.4f count=%d sdev=%.4f",
				$totals[$i]/$counts[$i],
				$counts[$i],
				$sdev;
	}
	print "\n";
}


$timefmt = "%H:%M:%S" if $autodetect_time;  # default

my $cmd = "";

if ($opt{o}) {
	if ($opt{o} =~ m/\.png$/) {
		$cmd .= "set terminal png size 800,600 enhanced font 'arial'\n";
		$cmd .= "set output '$opt{o}'\n";
	} elsif ( $opt{o} =~ m/dumb/ ) {
		$cmd .= "set terminal $opt{o}\n";
	} else {
		die "Unknown image file type: $opt{o}";
	}
}

if ($timefmt) {
	$cmd .= "set xdata time\n";
    $cmd .= "set timefmt '$timefmt'\n";
}

$cmd .= "set grid ytics lc rgb '#bbbbbb' lw 1 lt 0\n";
$cmd .= "set grid xtics lc rgb '#bbbbbb' lw 1 lt 0\n";
#$cmd .= "set ytics nomirror\n";
#$cmd .= "set y2tics\n";
$cmd .= "set title '$opt{T}'\n" if $opt{T};
#$cmd .= "set style data histogram\nset style histogram cluster gap 1\n" if $opt{H};
$cmd .= "set pointsize 0.4\n";
$cmd .= "set boxwidth 1 relative\n" if $opt{H};
$cmd .= "set boxwidth 0.5 relative\n" if $opt{P};
$cmd .= $labels if $opt_L;
$cmd .= "plot ";

$opt_l || shift @select_idx;

my $i = 0;
while ($i <= $#select_idx) {
	$cmd .= " '/tmp/plot.tmp.$username.$$.dat' ";
	my $ii = $i+1-$opt_l;
	my $fld = $ii+1;
	$fld = '($'.$fld.'*'.(1/($max[$ii] - $min[$ii])).")" if ($opt_a && $min[$ii] != $max[$ii]);
	if ($opt{l}) {
		$cmd .= "using $fld";
	} else {
		$cmd .= "using 1:$fld";
	}
	$cmd .= ":".($i+3).":".($i+4).":".($i+5) if ($opt{P});
	$cmd .= " with";
	$cmd .= " boxes" if $opt{H};
	$cmd .= " $opt{w}" if !$opt{H};
	#$cmd .= " axes x1y2" if $opt{a};
	$cmd .= " title '";
	$cmd .= '(cumulative) ' if $opt_C;
	$cmd .= ($opt{P} ? "price": $columns[$select_idx[$i]]);
	$cmd .= "*".sprintf("%g", 1/($max[$ii] - $min[$ii])) if ($opt_a && $min[$ii] != $max[$ii]);
	$cmd .= " mean=".sprintf("%g", $totals[$ii]/$counts[$ii]) if $counts[$ii] && $opt{S} =~ m/m/;
	$cmd .= " sdev=".sprintf("%g", sqrt( ($totals2[$ii]  - $totals[$ii] * $totals[$ii] / $counts[$ii]) / $counts[$ii])) if $counts[$ii] && $opt{S} =~ m/s/;
	$cmd .= " sharpe=".sprintf("%g", $totals[$ii]/$counts[$ii]/sqrt( ($totals2[$ii]  - $totals[$ii] * $totals[$ii] / $counts[$ii]) / $counts[$ii])) if $counts[$ii] && $opt{S} =~ m/p/;
	$cmd .= " drawdown=".sprintf("%g[%d]", $drawdown[$ii], $n_drawdown[$ii]) if $counts[$ii] && $opt{S} =~ m/d/;
	$cmd .= " n=".$counts[$ii] if $counts[$ii];
	$cmd .= "'";
	$i +=3 if ($opt{P});
	$cmd .= "," if ($i < $#select_idx);
	$i ++;
}

$cmd .= "\n";
if ($opt{m}) {
	$cmd .= "pause mouse close\n";
}

print $cmd if $opt{v};

open CMD, "> /tmp/plot.tmp.$username.$$.gpi" or die "cannot open tmp cmd file: $!\n";
print CMD "$cmd";
close CMD;

exec ("gnuplot -persist /tmp/plot.tmp.$username.$$.gpi && rm -f /tmp/plot.tmp.$username.$$.{gpi,dat} &");
