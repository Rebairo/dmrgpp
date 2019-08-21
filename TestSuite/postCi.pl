#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case);
use lib ".";
use Ci;
use lib "../scripts";
use timeObservablesInSitu;
use Metts;

my ($failed,$su2,$help,$workdir,$golddir,$ranges,$info);
GetOptions(
'n=s' => \$ranges,
'f' => \$failed,
'su2' => \$su2,
'i=i' => \$info,
'h' => \$help,
'g=s' => \$golddir,
'w=s' => \$workdir);

my $defaultGold = "../../OraclesDmrgpp/oracles/tests";

if (defined($help)) {
	print "USAGE: $0 [options]\n";
	print "\tIf no option is given examines all runs\n";
	print Ci::helpFor("-n");
	print Ci::helpFor("-w");
	print "\t-g golddir\n";
	print "\t\tUse golddir for oracles directory instead of the ";
	print "default of $defaultGold\n";
	print "\t-f\n";
	print "\t\tPrint info only about failed tests\n";
	print Ci::helpFor("-su2");
	print "\t-i number\n";
	print "\t\tPrint info for test number number\n";
	print Ci::helpFor("-h");
	exit(0);
}

defined($failed) or $failed = 0;
defined($su2) or $su2 = 0;
defined($workdir) or $workdir = "tests";
defined($golddir) or $golddir = $defaultGold;

my @tests = Ci::getTests("inputs/descriptions.txt");
my %allowedTests = Ci::getAllowedTests(\@tests);
my $total = $tests[$#tests]->{"number"};

if (defined($info)) {
	print STDERR "$0: INFO for $info\n";
	print STDERR " ".$allowedTests{$info}."\n";
	exit(0);
}

my @inRange = Ci::procRanges($ranges, $total);
my $rangesTotal = scalar(@inRange);

die "$0: No tests specified under -n\n" if ($rangesTotal == 0);

for (my $j = 0; $j < $rangesTotal; ++$j) {
	my $n = $inRange[$j];
	if (!exists($allowedTests{"$n"})) {
		#print STDERR "$0: Test $n does not exist, ignored\n";
		next;
	}

	if ($n == 120) {
		print STDERR "$0: |$n| ignored\n";
		next;
	}

	my $thisInput = Ci::getInputFilename($n);
	$thisInput =~ s/\.\.\///;

	my %keys = Ci::getInfoFromInput($thisInput, $n);
	my $isSu2 = Ci::isSu2(\%keys);
	if ($isSu2 and !$su2) {
		print STDERR "$0: WARNING: Ignored test $n ";
		print STDERR "because it's NOT an SU(2) test and ";
		print STDERR "you did not specify -su2\n";
		next;
	}

	my $solverOpts = $keys{"SolverOptions"};
	my $targetName = "GroundStateTargeting";
	defined($solverOpts) or $solverOpts = ""; 
	if ($solverOpts =~ /Targeting/ && !($solverOpts =~ /GroundStateTargeting/)) {
		$targetName = "NGST";
	}

	procTest($n, $workdir, $golddir, $targetName);

	my @ciAnnotations = Ci::getCiAnnotations($thisInput, $n);
	my $totalAnnotations = scalar(@ciAnnotations);

	my @postProcessLabels = qw(getTimeObservablesInSitu getEnergyAncilla CollectBrakets metts observe);
	my %actions = (getTimeObservablesInSitu => \&checkTimeInSituObs,
	               getEnergyAncilla => \&checkEnergyAncillaInSitu,
	               CollectBrakets => \&checkCollectBrakets,
	               metts => \&checkMetts,
	               observe => \&checkObserve,
	               procOmegas => \&checkProcOmegas);
	for (my $i = 0; $i < $totalAnnotations; ++$i) {
		my ($ppLabel, $w) = Ci::readAnnotationFromIndex(\@ciAnnotations, $i);
		my $x = defined($w) ? scalar(@$w) : 0;
		next if ($x == 0);
		print "|$n| has $x $ppLabel lines\n";
		if ($ppLabel eq "dmrg" || $ppLabel eq "nDollar") {
			print "|$n| ignoring $ppLabel label in postCi mode\n";
			next;
		}

		$actions{$ppLabel}->($n, $w, $workdir, $golddir);
	}

	print "-----------------------------------------------\n";
}

sub procTest
{
	my ($n, $workdir, $golddir, $targetName) = @_;
	my %newValues;
	my %oldValues;
	procCout(\%newValues, $n,$workdir);
	procCout(\%oldValues, $n, $golddir);
	compareValues(\%newValues, \%oldValues, $n, $targetName);
	procMemcheck($n);
}

sub procCout
{
	my ($values, $n, $dir) = @_;
	my $file = "$dir/runForinput$n.cout";
	if (!(-r "$file")) {
		print "|$n|: No $file found\n";
		return;
	}

	open(FILE, "<", "$file") or return;
	my @energies;
	my $counter = 0;
	while (<FILE>) {
		chomp;
		if (/DMRG\+\+ version (.*$)/) {
			$values->{"Version"} = $1;
			next;
		}

		if (/lowest eigenvalue= ([^ ]+) /) {
			push(@energies, $1);
			next;
		}

		if (/DmrgSolver \[([\d\.]+)\]\: Turning off the engine/) {
			$values->{"UserTime"} = $1;
		}

		if (/Current virtual memory is/) {
			if (/maximum was (.+)$/) {
				$values->{"MaxRAM"} = $1;
			}
		}
	}

	close(FILE);
	$values->{"Energies"} = \@energies;
}

sub compareValues
{
	my ($newValues, $oldValues, $n, $targetName) = @_;
	foreach my $key (sort keys %$oldValues) {
		my $v1 = $newValues->{"$key"};
		my $v2 = $oldValues->{"$key"};
		defined($v1) or $v1 = "UNDEFINED";
		defined($v2) or $v2 = "UNDEFINED";
		if ($key ne "Energies") {
			print "|$n|: $key: $v1 $v2\n";
			next;
		}

		my $maxEdiff = maxEnergyDiff($newValues->{$key}, $oldValues->{$key});
		next if ($targetName ne "GroundStateTargeting" and $maxEdiff eq "NO ENERGIES!");
		print "|$n|: MaxEnergyDiff = $maxEdiff   .$targetName.\n";
	}
}

sub maxEnergyDiff
{
	my ($eNew, $eOld) = @_;
	return "NEW ENERGIES UNDEFINED" if (!defined($eNew));
	return "OLD ENERGIES UNDEFINED" if (!defined($eOld));
	my $n = scalar(@$eNew);
	return "ENERGY SIZES DIFFERENT" if (scalar(@$eOld) != $n);
	return "NO ENERGIES!" if ($n == 0);
	my $maxEdiff = 0;
	for (my $i = 0; $i < $n; ++$i) {
		my $tmp = abs($eNew->[$i] - $eOld->[$i]);
		$maxEdiff = $tmp if ($tmp > $maxEdiff);
	}

	return "$maxEdiff [out of $n]";
}

sub procMemcheck
{
	my ($n) = @_;
	my $file1 = "$workdir/output$n.txt";
	my $mode = "OK";
	my $extra = "UNDEFINED";
	my %lost;
	my $ret = open(FILE, "<", $file1);
	if (!$ret) {
		print STDERR "$0: Cannot open $file1 : $!\n";
		return;
	}

	while (<FILE>) {
		if (/FATAL: You are requesting/ || /mandatory label/) {
			$mode = "FATAL";
			$extra = $_;
			chomp($extra);
			last;
		}

		if (/terminate called after throwing/) {
			$mode = uc("throw");
			while (<FILE>) {
				if (/what\(\)/) {
					$extra = $_;
					chomp($extra);
					last;
				}
			}

			last;
		}
		next unless (/^==/);
		if (/invalid/i) {
			$mode = uc("invalid");
			last;
		}

		if (/uninitial/i) {
			$mode = uc("uninitialized");
			last;
		}

		if (/([^ ]+) lost: ([^ ]+) bytes/) {
			my $val = $2;
			my $name = $1;
			$val =~ s/,//;
			$lost{"$name"}= $val;
			next;
		}
	}

	close(FILE);

	if ($mode eq "FATAL" || $mode eq uc("throw")) {
		print "|$n|: ".uc($mode)." couldn't run because of $extra\n";
		return;
	}

	foreach my $key (keys %lost) {
		my $val = $lost{"$key"};
		next if ($val == 0);
		print "|$n|: WARNING: $key lost ".$lost{"$key"}." bytes\n";
	}
}

sub fileSize
{
	my ($filename) = @_;
	my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
	          $atime,$mtime,$ctime,$blksize,$blocks)
	              = stat($filename);
	return $size;
}

sub checkEnergyAncillaInSitu
{
	my ($n, $what, $workdir, $golddir) = @_;
	my $whatN = scalar(@$what);
	for (my $i = 0; $i < $whatN; ++$i) {
		my $file = "runForinput$n.cout";
		if (!(-r "$file")) {
			print STDERR "|$n|: WARNING: $file not readable ".__LINE__."\n";
		}

		my $file1 = "$workdir/energyAncillaInSitu${n}_$i.txt";
		my $file2 = "$golddir/energyAncillaInSitu${n}_$i.txt";
		print "kompare $file1 $file2\n";
		my %vals1 = Metts::load($file1);
		my %vals2 = Metts::load($file2);
		compareHashes(\%vals1, \%vals2);
	}
}

sub checkTimeInSituObs
{
	my ($n, $what, $workdir, $golddir) = @_;
	my $whatN = scalar(@$what);
	for (my $i = 0; $i < $whatN; ++$i) {
		my $file1 = "$workdir/timeObservablesInSitu${n}_$i.txt";
		my $file2 = "$golddir/timeObservablesInSitu${n}_$i.txt";
		print "kompare $file1 $file2\n";
		my %m1 = timeObservablesInSitu::load($file1);
		my %m2 = timeObservablesInSitu::load($file2);
		if (keys %m1 != 4 or keys %m2 != 4) {
			print "\tIncorrect file $file1 or $file2\n";
			return;
		}

		my $site = $m1{"site"};
		my $label = $m1{"label"};
		if ($label ne $m2{"label"}) {
			print "\tlabels NOT EQUAL\n";
			next;
		}

		if ($site ne $m2{"site"}) {
			print "\tsites NOT EQUAL\n";
			next;
		}

		print "\tChecking times...\n";
		checkVectorsEqual($m1{"times"}, $m2{"times"});

		compareMatrices($m1{"data"}, $m2{"data"});
	}
}

sub checkCollectBrakets
{
	my ($n, $what, $workdir, $golddir) = @_;
	my $whatN = scalar(@$what);
	for (my $i = 0; $i < $whatN; ++$i) {
		my $file = "runForinput$n.cout";
		if (!(-r "$file")) {
			print STDERR "|$n|: WARNING: $file not readable ".__LINE__."\n";
		}

		my $file1 = "$workdir/CollectBrakets${n}_$i.txt";
		my $file2 = "$golddir/CollectBrakets${n}_$i.txt";
		my %brakets1 = readBrakets($file1);
		my %brakets2 = readBrakets($file2);
		print "$0: kompare $file1 $file2\n";
		compareBrakets(\%brakets1, \%brakets2);
	}
}

sub compareBrakets
{
	my ($b1, $b2) = @_;
	my $n1 = scalar(keys %$b1);
	my $n2 = scalar(keys %$b2);
	if ($n1 != $n2) {
		print "WARNING: Braket n. of labels differs $n1 != $n2\n";
	}

	my @ks = ($n1 < $n2) ? keys %$b2 : keys %$b1;
	foreach my $label (@ks) {
		my $a1 = $b1->{"$label"};
		my $a2 = $b2->{"$label"};
		if (!defined($a1)) {
			print "Warning, Braket with label $label not in working dir\n";
			next;
		}

		if (!defined($a2)) {
			print "Warning, Braket with label $label not in gold dir\n";
			next;
		}

		compareBraketGivenLabel($a1, $a2, $label);
	}
}

sub compareBraketGivenLabel
{
	my ($a1, $a2, $label) = @_;
	my $n1 = scalar(@$a1);
	my $n2 = scalar(@$a2);
	if ($n1 != $n2) {
		print "WARNING: Braket $label n. of sites differs $n1 != $n2\n";
	}

	my @items = ("time", "value", "norm");
	my $n = ($n1 < $n2) ? $n1 : $n2;
	for (my $site = 0; $site < $n; ++$site) {
		my $h1 = $a1->[$site];
		my $h2 = $a2->[$site];
		defined($h1) or next;
		defined($h2) or next;
		foreach my $item (@items) {
			if (compareItem($item, $h1, $h2) > 1) {
				 print "$0 $item undefined either old or new\n";
				 return;
			}
		}
	}
}

sub compareItem
{
	my ($item, $h1, $h2) = @_;
	my $i1 = $h1->{"$item"};
	my $i2 = $h2->{"$item"};
	return 0 if (!defined($i1) and !defined($i2));
	defined($i1) or return 2;
	defined($i2) or return 3;
	my $f1 = isFloat($i1);
	my $f2 = isFloat($i2);
	
	if ($f1 and $f2) {
		return (abs($f1 - $f2) < 1e-6) ? 0 : 1;
	}

	my ($re1, $im1) = getReImag($i1);
	my ($re2, $im2) = getReImag($i2);
	if ($re1 and $re2) {
		return (abs($re1 - $re2) < 1e-6 and abs($im1 - $im2) < 1e-6) ? 0 : 1;
	}

	if ($i1 ne $i2) {
		print "$0 $item differs in $item $i1 != $i2\n";
	}

	return ($i1 eq $i2) ? 0 : 1;
}

sub getReImag
{
	my ($val) = @_;
	if ($val =~ /^\(([^\,]+)\,([^\)]+)\)$/) {
		return ($1, $2);
	}

	return ("", "");
}

sub readBrakets
{
	my ($file) = @_;
	my %brakets;
	if (!open(FILE, "<", $file)) {
		print "$0: Could not open $file : $!\n";
		return %brakets;
	}

	while (<FILE>) {
		my @temp = split;
		next if (scalar(@temp) != 5);
		my $site = $temp[0];
		next unless ($site =~ /^\d+$/);
		my $label = $temp[3];
		my $hptr = {"value" => $temp[1], "time" => $temp[2], "norm" => $temp[4]};
		my $aptr = $brakets{"$label"};
		if (defined($aptr)) {
			$brakets{"$label"}->[$site] = $hptr;
		} else {
			my @aOfSites;
			$aOfSites[$site] = $hptr;
			$brakets{"$label"} = \@aOfSites;
		}
	}

	close(FILE);
	return %brakets;
}

sub checkVectorsEqual
{
	my ($a, $b) = @_;
	my $n = scalar(@$a);
	if ($n != scalar(@$b)) {
		print "\t\tSIZES NOT EQUAL\n";
		return 0;
	}

	my $max = 0;
	for (my $i = 0; $i < $n; ++$i) {
		$_ = abs($a->[$i] - $b->[$i]);
		$max = $_ if ($max < $_);
	}

	print "\t\tMax diff=$max\n";
}

sub checkMetts
{
	my ($n,$what,$workdir, $golddir) = @_;
	my $whatN = scalar(@$what);
	for (my $i = 0; $i < $whatN; ++$i) {
		my $file1 = "$workdir/metts${n}_$i.txt";
		my $file2 = "$golddir/metts${n}_$i.txt";
		my %vals1 = Metts::load($file1);
		my %vals2 = Metts::load($file2);
		compareHashes(\%vals1, \%vals2);
	}
}

sub checkProcOmegas
{
	my ($n, $what, $workdir, $golddir) = @_;
	my $file1 = "$workdir/out$n.spectrum";
	my $file2 = "$golddir/out$n.spectrum";
	print "$0: kompare $file1 $file2\n";
	compareSpectrum($file1, $file2);
}

sub compareSpectrum
{
	my ($file1, $file2) = @_;

	my %h1;
	loadSpectrum(\%h1, $file1);

	my %h2;
	loadSpectrum(\%h2, $file2);

	compareSpectrumHashes(\%h1, \%h2);
}

sub loadSpectrum
{
	my ($h, $file) = @_;
	if (!open(FILE, "<", $file)) {
		print "\t\tWARNING: $file could not be opened\n";
		return;
	}

	while (<FILE>) {
		next if (/^[ \t]*#/);
		chomp;
		my @temp = split;
		my $n = scalar(@temp);
		next if ($n < 2);
		my $key = shift @temp;
		
		$h->{"$key"} = \@temp;
	}

	close(FILE); 
}

sub compareSpectrumHashes
{
	my ($h1, $h2) = @_;
	my $n1 = keys %$h1;
	my $n2 = keys %$h2;
	print "\t\tWARNING:Spectrum: Different number of omegas $n1 and $n2\n"
	 if ($n1 != $n2);

	my $maxDiff = 0;
	my @omegasUndef;
	foreach my $key (sort keys %$h1) {
		my $vec1 = $h1->{$key};
		my $vec2 = $h2->{$key};
		if (defined($vec2)) {
			my $diff = vectorAbsDiff($vec1, $vec2);
			$maxDiff = $diff if ($diff > $maxDiff);
		} else {
			push @omegasUndef, $key;
		}
	}

	my $n = scalar(@omegasUndef);
	print "\t\t WARNING:Spectrum: $n omegas not found\n" if ($n > 0);
	my $warnOrNot = ($maxDiff < 1e-5) ? "" : "WARNING"; 
	print "\t\t$warnOrNot"."Spectrum: maxDiff=$maxDiff\n";
}

sub vectorAbsDiff
{
	my ($v1, $v2) = @_;
	my $n1 = scalar(@$v1);
	my $n2 = scalar(@$v2);
	print "\t\tWARNING:Spectrum: Different number of space points $n1 and $n2\n"
	 if ($n1 != $n2);

	my $max = ($n1 < $n2) ? $n2 : $n1;
	my $maxDiff = 0;
	for (my $i = 0; $i < $max; ++$i) {
		my $val1 = $v1->[$i];
		my $val2 = $v2->[$i];
		defined($val1) or $val1 = 0;
		defined($val2) or $val2 = 0;
		my $diff = abs($v1->[$i] - $v2->[$i]);
		$maxDiff = $diff if ($diff > $maxDiff);
	}

	return $maxDiff;
}


sub checkObserve
{
	my ($n, $ignored, $workdir, $golddir) = @_;
	my $file1 = "$workdir/observe$n.txt";
	my $file2 = "$golddir/observe$n.txt";
	print "$0: kompare $file1 $file2\n";
	my @m1 = loadObserveData($file1);
	my @m2 = loadObserveData($file2);
	compareObserveData(\@m1, \@m2);
}

sub compareObserveData
{
	my ($m1, $m2) = @_;
	my $n1 = scalar(@$m1);
	my $n2 = scalar(@$m2);
	print "work has $n1 observe matrices -- gold has $n2 observe matrices\n";
	return if ($n1 != $n2);
	for (my $i = 0; $i < $n1; ++$i) {
		compareObserveDatum($m1->[$i], $m2->[$i]);
	}
}

sub compareObserveDatum
{
	my ($h1, $h2) = @_;
	my $l1 = $h1->{"label"};
	my $l2 = $h2->{"label"};
	if ($l1 ne $l2) {
		print "Label $l1 NOT EQUAL to $l2\n";
		return;
	}

	print "Comparing $l1\n";
	compareMatrices($h1->{"data"}, $h2->{"data"});
}

sub compareMatrices
{
	my ($m1, $m2) = @_;
	if (scalar(@$m1) < 3 || scalar(@$m2) < 3) {
		print "\tMatrix TOO SMALL\n";
		return;
	}

	if ($m1->[0] != $m2->[0]) {
		print "\tRows not equal\n";
		return;
	}

	if ($m1->[1] != $m2->[1]) {
		print "\tCols not equal\n";
		return;
	}

	my $total = $m1->[0] * $m1->[1];

	my $max = 0;
	for (my $i = 0; $i < $total; ++$i) {
		my $val = abs($m1->[$i] - $m2->[$i]);
		$max = $val if ($max < $val);
	}

	print "\tMaximum difference= $max\n";
}


sub loadObserveData
{
	my ($file) = @_;
	my @m;
	my $fh;
	if (!open($fh, "<", "$file")) {
		print "$0: File $file NOT FOUND\n";
		return @m;
	}

	while (<$fh>) {
		my $label = readNextLabel($fh);
		my @m1;
		my $ret = readNextMatrix($fh, \@m1);
		if ($ret ne "ok") {
			print "$0: $ret\n";
			print "$0: $label\n" if (defined($label));
			last;
		}

		my %h = ("label" => $label, "data" => \@m1);
		push @m, \%h;
	}

	close($fh);
	return @m;
}

sub readNextLabel
{
	my ($fh) = @_;
	while (<$fh>) {
		#print;
		chomp;
		last if (/^\</);
	}

	return $_;
}

sub readNextMatrix
{
	my ($fh, $m) = @_;
	$_ = <$fh>;
	defined($_) or return "eof";
	chomp;
	if (!/^\d+ /) {
		# double label, read again
		$_ = <$fh>;
		defined($_) or return "eof";
		chomp;
	}

	my @temp = split;

	if (scalar(@temp) != 2) {
		return "not a matrix";
	}


	my ($rows, $cols) = @temp;
	$m->[0] = $rows;
	$m->[1] = $cols;
	for (my $i = 0; $i < $rows; ++$i) {
		$_ = <$fh>;
		defined($_) or return "file ended while reading matrix";
		chomp;
		my @temp = split;
		(scalar(@temp) == $cols) or return "cols wrong for row $i";
		for (my $j = 0; $j < $cols; ++$j) {
			$m->[2 + $i +$j*$rows] = $temp[$j];
		}
	}

	return "ok";
}

sub compareHashes
{
	my ($h1, $h2) = @_;
	my $max = 0;
	foreach my $key1 (keys %$h1) {
		my $val2 = $h2->{"$key1"};
		if (!defined($val2)) {
			print "\tNot value for $key1 in hash2\n";
			next;
		}

		my $val1 = $h1->{"$key1"};
		my $d = abs($val1->[0] - $val2->[0]);
		$max = $d if ($max < $d);
	}

	print "Maximum Error $max\n";
}

sub isFloat
{
	my ($x) = @_;
	$_ = $x;
	return (/^[+-]?(?=\.?\d)\d*\.?\d*(?:e[+-]?\d+)?\z/i);
}

