#!/usr/bin/env perl
# Process a resulting VCF: make an MSA; remove uninformative sites; find pairwise distances;
# find Fst; make a tree; calculate the eigenvector
# Author: Lee Katz <lkatz@cdc.gov>

use strict;
use warnings;
use Data::Dumper;
use Getopt::Long;
use File::Basename;
use File::Spec;
use File::Temp qw/tempdir/;
use Bio::Perl;
use Bio::TreeIO;
use File::Copy qw/move copy/;
use threads;
use Thread::Queue;

use FindBin;
use lib "$FindBin::RealBin/../lib";
use LyveSET qw/logmsg/;

exit main();

sub main{
  local $0=basename $0;
  my $settings={};

  GetOptions($settings,qw(help prefix=s numcpus=i tempdir=s));
  $$settings{prefix}||="./out";
  $$settings{numcpus}||=1;
  $$settings{tempdir}||=tempdir("XXXXXX",TMPDIR=>1,CLEANUP=>1);
  
  my($VCF)=@ARGV;
  die usage() if(!$VCF || $$settings{help});

  my $snpMatrix="$$settings{prefix}.snpmatrix.tsv";
  my $filteredMatrix="$$settings{prefix}.filteredMatrix.tsv";
  logmsg "Creating a SNP matrix from $VCF";
  system("pooledToMatrix.sh -o $$settings{prefix}.snpmatrix.tsv $VCF");
  die "ERROR with pooledToMatrix" if $?;

  system("filterMatrix.pl --noinvariant-loose < $snpMatrix > $filteredMatrix");
  die if $?;

  my $unfilteredAlignment="$$settings{prefix}.aln.fasta";
  my $filteredAlignment="$$settings{prefix}.informative.fasta";
  system("matrixToAlignment.pl < $snpMatrix > $unfilteredAlignment");
  die if $?;

  system("matrixToAlignment.pl < $filteredMatrix > $filteredAlignment");
  die if $?;

  my $pairwise="$$settings{prefix}.pairwise.tsv";
  my $pairwiseMatrix="$$settings{prefix}.pairwiseMatrix.tsv";
  system("pairwiseDistances.pl --numcpus $$settings{numcpus} < $filteredAlignment | sort -k3,3n | tee $pairwise | pairwiseTo2d.pl > $pairwiseMatrix");
  die if $?;

        # Process a resulting VCF: make an MSA; remove uninformative sites; find pairwise distances;
        # find Fst; make a tree; calculate the eigenvector
  my $indexCase="$$settings{prefix}.eigen.tsv";
  system("set_indexCase.pl $pairwise | sort -k2,2n > $indexCase");
  die "ERROR with set_indexCase.pl" if $?;

  # TODO Fst

  # RAxML puts everything into the CWD and so we have to work around that.
  system("cp $filteredAlignment $$settings{tempdir}/; cd $$settings{tempdir}; launch_raxml.sh -n $$settings{numcpus} $filteredAlignment suffix");
  die "ERROR with launch_raxml.sh" if $?;
  for (qw(RAxML_bestTree RAxML_bipartitionsBranchLabels RAxML_bipartitions RAxML_bootstrap RAxML_info)){
    system("mv -v $$settings{tempdir}/$_.suffix $$settings{prefix}.$_");
    die "ERROR: could not move $$settings{tempdir}/$_.suffix: $!" if $?;
  }

  # TODO: reroot the tree
  #rerootLongestBranch("$$settings{prefix}.RAxML_bipartitions",$settings);

  # Get combined distance statistics on the tree
  system("cladeDistancesFromTree.pl -t $$settings{prefix}.RAxML_bipartitions -p $$settings{prefix}.pairwise.tsv --outprefix $$settings{prefix}");
  die "ERROR with cladeDistancesFromTree.pl" if $?;

  return 0;
}

sub rerootLongestBranch{
  my($file,$settings)=@_;
  
  my $tmpTree="$file.rerooted";
  my $tree=Bio::TreeIO->new(-file=>$file,-format=>"newick")->next_tree;
  my $out=Bio::TreeIO->new(-file=>">$tmpTree",-format=>"newick");

  my @node=$tree->get_nodes;
  my $outgroup=$node[0];
  my $longest=$node[0]->branch_length || 0;

  for(my $i=1;$i<@node;$i++){
    if($node[$i]->branch_length() > $longest){
      $longest=$node[$i]->branch_length;
      $outgroup=$node[$i];
      #print join("\t",$outgroup->id,$longest)."\n";
    }
  }

  $tree->reroot($outgroup);
  
  $out->write_tree($tree);
  system("mv -v $tmpTree $file");
  die if $?;
}

sub usage{
  local $0=basename $0;
  "Process a pooled VCF and get useful information
  Usage: $0 file.vcf.gz
  --prefix  ./out     Output file prefix. Default: current working directory
  --numcpus 1         Number of threads to use
  "
}
