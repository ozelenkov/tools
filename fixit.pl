#!/usr/bin/perl -w

use strict;
use Getopt::Std;
use POSIX;


my %opt=();
getopts("0s:S:C:k:nDHA:f:k:q:h", \%opt);

# print help
if ($opt{h}) {
	print qq~Usage: fix [options] [input-file]
Options:
    -q <separator> - separator char (defaults to comma)
    -C <column>    - cumulate column values
    -s <column>    - sort in ascending order
    -S <column>    - sort in descending order
    -0             - numerical sort
    -D             - don't verify columns count
    -n             - no formatting
    -H             - no header row
    -A <col>=<exp> - append a column with name 'col' defined by the expression 'exp' (may use other columns and/or Perl functions).
    -f <cond>      - filter out lines where the condition expression evaluates to false
    -k <c1,c2...>  - kill all columns except c1,c2...
qq~;
	exit;
}

die "Options -s and -S are mutualy exclusive" if $opt{s} and $opt{S};

sub sign($)
{
	my $v = shift;
	return ($v < 0)? -1: ($v > 0)? 1: 0;
}

sub prev_minute($)
{
	my $v = shift;
	my ($hh, $mm) = split (/:/, $v);
	$mm = ($mm == 0)? 59: $mm - 1;
	$hh-- if ($mm == 59);
	return sprintf("%02d:%02d", $hh, $mm);
}

sub bytes($)
{
	my $v = shift;
	my @b = unpack('c*', pack("N", $v));
	return join ('/', @b);
}

sub nonzero_bytes($)
{
	my $v = shift;
	my @b = unpack('c*', pack("N", $v));
	my @n = sort { $a <=> $b } grep { $_ > 0 } @b;
	return join ('/', @n);
}

# select input
my $fh;
if (defined $ARGV[0]) {
	open $fh, "<:encoding(utf8)", $ARGV[0] or die $ARGV[0].": $!";
}
else {
	$fh = *STDIN;
}

# detect column names

my $header = <$fh>;
$header or exit;  #empty file
chomp $header;
if (!$opt{q}) {
	my @c_p = split(/\|/, $header, -1);
	my @c_c = split(/,/, $header, -1);
	$opt{q} = ($#c_p == 0 && $#c_c == 0)? '\b\s+': ($#c_p > $#c_c)? '\|': ',';
}
my $pattern = "$opt{q}";
my @columns = split(/$pattern/, $header, -1);
my $header_columns = "@columns";

# append new column
my ($A_column, $A_expression, $A_value);
if ($opt{A}) {
	($A_column, $A_expression) = split /\s*=\s*/, $opt{A};
}
push @columns, $A_column if $opt{A};

# resolve column indices
my %idx_columns;
my @len;
my $idx = 0;
for my $fld (@columns) {
	$fld = 'col'.$idx if $opt{H};
	push @len, length($fld);
	$idx_columns{$fld} = $idx;
	$idx++;
}

# compile new column expression
if ($A_expression) {
	$A_expression = '$A_value='.$A_expression;
	for my $col_name (@columns) {
		if ($A_expression =~ m/\b$col_name\b/) {
			my $idx = $idx_columns{$col_name};
			$A_expression =~ s/\b$col_name\b/\$fields[$idx]/;
			$A_expression = "if (defined(\$fields[$idx])) {".$A_expression.";}";
		}
	}
	#print "$A_column = $A_expression\n";
}

# filter condition
my ($F_expression, $F_value);
if ($opt{f}) {
	$F_expression = '$F_value=('.$opt{f}.')';
	for my $col_name (@columns) {
		if ($F_expression =~ m/\b$col_name\b/) {
			my $idx = $idx_columns{$col_name};
			$F_expression =~ s/\b$col_name\b/\$fields[$idx]/;
			$F_expression = "if (defined(\$fields[$idx])) {".$F_expression.";}";
		}
	}
	#print "$F_expression\n";
}

# column filter
my @names_selected = @columns;
@names_selected = map { 'col'.$_ } (0..$#columns) if $opt{H};
@names_selected = split(/,/, $opt{k}) if $opt{k};
my @idx_selected = map { $idx_columns{$_} } @names_selected;

# calculate total
my $idxCum;
my $total = 0;
if ($opt{C}) {
	defined($idxCum = $idx_columns{$opt{C}}) or die "unknown column $opt{C}, available:". join(',', @columns);
}

# unformatted header
my $i;
if ($opt{n}) {
	$idx = 0;
	for $i (@idx_selected) {
		print ',' if $idx++;
		print $columns[$i];
	}
	print "\n";
}

my $dont_format = $opt{n} && !$opt{s} && !$opt{S};

#seek($fh, 0, 0) or die $! if $opt{H};  XXX not working

# parse csv table
my @rows;
while ( <$fh> ) {
	chomp;
	my @fields = split (/$pattern/, $_, -1);
	$opt{H} || next if "$header_columns" eq "@fields";
	$opt{D} || (warn "too many fields" and next) if $#fields > $#columns;
	#while ( $#fields < $#columns) {
	#	push @fields, undef;
	#}
	if ($opt{A}) {
		$A_value = '';
		eval $A_expression;
		#print "$A_value = $fields[3]*$fields[4]\n";
		push @fields, $A_value;
	}
	if ($opt{f}) {
		$F_value = 0;
		eval $F_expression;
		next if (!$F_value);
	}
	$total = $fields[$idxCum] += $total if $idxCum and defined($fields[$idxCum]);
	if ($dont_format) {
		$idx = 0;
		for $i (@idx_selected) {
			print ',' if $idx++;
			print $fields[$i] if defined($fields[$i]);
		}
		print "\n";
		next;
	}
    push @rows, [ @fields ];
	# update column widths
	next if $opt{n};
	$i = 0;
	while ($i <= $#fields && $i <= $#columns) {

		if ($len[$i] < length($fields[$i])) {
			$len[$i] = length($fields[$i]);
		}
		$i++;
	}
}

exit if $dont_format;

# sort in ascending order
if ($opt{s}) {
	defined($idx = $idx_columns{$opt{s}}) or die "unknown column $opt{s}, available: ". join(',', @columns);
	@rows = sort { $a->[$idx] cmp $b->[$idx] } @rows if !$opt{0};
	@rows = sort { $a->[$idx] <=> $b->[$idx] } @rows if $opt{0};
}

#sort in descending order
if ($opt{S}) {
	defined($idx = $idx_columns{$opt{S}}) or die "unknown column $opt{S}, available: ". join(',', @columns);
	@rows = sort { $b->[$idx] cmp $a->[$idx] } @rows if !$opt{0};
	@rows = sort { $b->[$idx] <=> $a->[$idx] } @rows if $opt{0};
}

# format and print header row
if (!$opt{n}) {
	for $i (@idx_selected) {
		print sprintf("%*s", $len[$i]+1, $columns[$i]);
	}
	print "\n";
}

# format and print data rows
for my $lineno (0..$#rows) {
	my @fields = @{$rows[$lineno]};
	if ($opt{n}) {
		$idx = 0;
		for $i (@idx_selected) {
			print ',' if $idx++;
			print $fields[$i] if defined($fields[$i]);
		}
	} else {
		for $i (@idx_selected) {
			print sprintf("%*s", $len[$i]+1, defined($fields[$i])? $fields[$i]: "");
		}
	}
	print "\n";
}
