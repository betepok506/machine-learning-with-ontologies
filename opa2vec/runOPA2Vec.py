import os
import sys
import argparse
import sys
import tempfile
#####################################################################################################################
# create a parser object
parser = argparse.ArgumentParser(description = "OPA2Vec is a tool to produce feature vectors for biological entities from an ontology.")
 
# add argument
parser.add_argument("-ontology", nargs = '?', metavar = "ontology OWL file", type = str, 
                     help = "File containing ontology in OWL format",default='')
parser.add_argument("-associations", nargs = '?', metavar = "association file", type = str, 
                     help = "File containing entity-class associations",default='')
parser.add_argument("-outfile", nargs = '?', metavar = "output file", type = str, 
                     help = "Output file with ontology embeddings",default='')
parser.add_argument("-embedsize", nargs = '?', metavar = "embedding size", type = int,default=200, 
                     help = "Size of obtained vectors")
parser.add_argument("-windsize", nargs = '?', metavar = "window size", type = int,default=5, 
                     help = "Window size for word2vec model")
parser.add_argument("-mincount", nargs = '?', metavar = "min count", type = int,default=0, 
                     help = "Minimum count value for word2vec model") 
parser.add_argument("-model", nargs = '?', metavar = "model", type = str,default='sg', 
                     help = "Preferred word2vec architecture, sg or cbow") 
parser.add_argument("-pretrained", nargs = '?', metavar ="pre-trained model", type =str, default ="RepresentationModel_pubmed.txt", help= "Pre-trained word2vec model for background knowledge")

parser.add_argument("-entities", nargs = '?', metavar = "entities file", type = str, default="finalclasses.lst",
                     help = "File containing list of of biological entities for which you would like to get the feature vectors (each entity in a separate line)")
parser.add_argument("-annotations", nargs='?',metavar="metadata annotations", type = str, default="all", help = "Full URIs of annotation properties to be included in metadata -separated by a comma ,- use 'all' for all annotation properties (default) or 'none' for no annotation property ")
parser.add_argument("-reasoner", nargs = '?', metavar = "reasoner", type = str,default='elk', 
                     help = "Preferred reasoner, hermit or elk")
parser.add_argument("-annotate_metadata",nargs= '?', metavar = "annotate metadata", type =str, default ='no',help="yes/no (default). If set to yes, annotates metadata with ontology terms")

# parse the arguments from standard input
args = parser.parse_args()
ontology_file =args.ontology
association_file=args.associations
classes_file=args.entities
window=args.windsize
embedding=args.embedsize
mincoun=args.mincount
model=args.model
pretrained =args.pretrained
listofuri=args.annotations
reasoner=args.reasoner 
outfile =args.outfile
annot = args.annotate_metadata

if (ontology_file is '' ):
	print ("\nError:Mandatory ontology file missing. For help, run: python runOPA2Vec.py --help\n")
	sys.exit()
if (association_file is ''):
	print ("\nError:Mandatory association file missing. For help, run: python runOPA2Vec.py --help\n")
	sys.exit()
if (outfile is ''):
	print ("\nError:Mandatory output-file name missing. For help, run: python runOPA2Vec.py --help\n")
	sys.exit()

if (model != 'sg' and model != 'cbow'):
	model ='sg'
###################################################################################################################
# Create the needed temporary files
#1. For ontology processing
axiomsinf = tempfile.NamedTemporaryFile()
axiomsorig =tempfile.NamedTemporaryFile()
classesfile =tempfile.NamedTemporaryFile()
axioms =tempfile.NamedTemporaryFile()
#2. For metadata extraction
metadatafile = tempfile.NamedTemporaryFile()
annotated_meta = tempfile.NamedTemporaryFile()
#3. For class extraction
annot_classes =tempfile.NamedTemporaryFile()
allclasses = tempfile.NamedTemporaryFile()
finalclasses = tempfile.NamedTemporaryFile()
#4. For associations
AssoAxiomInferred = tempfile.NamedTemporaryFile()
Assoc1 = tempfile.NamedTemporaryFile()
Assoc2 = tempfile.NamedTemporaryFile()
#5. For vector production
ontology_corpus = tempfile.NamedTemporaryFile()
tempvecs = tempfile.NamedTemporaryFile()

###################################################################################################################
print("	\n		*********** OPA2Vec Running ... ***********\n")

#1. Extract ontology axioms and classes
print("\n		1.Ontology Processing ...\n")
cmdonto ="groovy opa2vec/ProcessOntology.groovy " + str(ontology_file) +" "+str(reasoner) + " "+ str(axiomsinf.name)+" "+str(axiomsorig.name)+" "+str(classesfile.name)
print(f"Команда запсука: {cmdonto}")
os.system(cmdonto)

cmdMerge ="cat " +str(axiomsorig.name)+" "+str(axiomsinf.name)+" >"+str(axioms.name)
print(f"Команда запсука: {cmdMerge}")
os.system(cmdMerge)

cmdgetclas="perl opa2vec/getclasses.pl "+str(association_file)+" "+str(annot_classes.name)
print(f"Команда запсука: {cmdgetclas}")
os.system(cmdgetclas)

cmdclas1="cat "+str(classesfile.name)+" "+str(annot_classes.name)+" > "+ str(allclasses.name)
print(f"Команда запсука: {cmdclas1}")
os.system(cmdclas1)

cmdclas2 ="sort -u "+str(allclasses.name)+ " > " + str (finalclasses.name)
print(f"Команда запсука: {cmdclas2}")
os.system(cmdclas2)
print ("\n   ######################################################################\n")

#2. Extract and annotate metadata
print("\n		2.Metadata Extraction ...\n")
cmdmeta ="groovy opa2vec/getMetadata.groovy "+ str(ontology_file)+" "+str(listofuri)+" " + str(metadatafile.name)
print(f"Команда запсука: {cmdmeta}")
os.system(cmdmeta)
if (annot == 'yes' or annot == 'Yes' or annot == 'YES'):
	print ("\n 	2.1. Metadata annotation ...")	
	cmdannotat="perl opa2vec/AnnotateMetadata.pl" + str(metadatafile.name) + "> " +str(annotated_meta.name)
	print(f"Команда запсука: {cmdannotat}")
	os.system(cmdannotat)
print ("\n   ######################################################################\n")

#3. Process associations
print("\n		3.Propagate Associations through hierarchy ...\n")
cmdanc="perl opa2vec/AddAncestors.pl "+ str(association_file)+ " "+str(axioms.name)+" "+str(classesfile.name)+" "+ str(AssoAxiomInferred.name)
os.system(cmdanc)
cmdasso= "cat "+str(association_file)+" "+str(AssoAxiomInferred.name) +" > "+ str(Assoc1.name)
os.system(cmdasso)
cmdsort="sort -u "+ str(Assoc1.name) +" > "+ str(Assoc2.name)
print(f"Команда запсука: {cmdsort}")
os.system(cmdsort)
print ("\n   ######################################################################\n")

#4. Create corpus
print("\n		4.Corpus Creation ...\n")
if (annot == 'yes' or annot == 'Yes' or annot == 'YES'):
	cmdcorpus="cat "+ str(axioms.name)+ " "+str(annotated_meta.name)+" "+str(Assoc2.name)+" > "+str(ontology_corpus.name)
else:
	cmdcorpus="cat axioms.lst metadata.lst AllAssociations.lst  > ontology_corpus.lst"
	cmdcorpus="cat "+str(axioms.name)+" "+str(metadatafile.name)+" "+str(Assoc2.name)+" > "+ str(ontology_corpus.name)
print(f"Команда запсука: {cmdcorpus}")
os.system(cmdcorpus)
print ("\n  ######################################################################\n")

#5. Run Word2Vec
tempoutfile ="tempout"
print("\n		5.Running Word2Vec ... \n")
cmdwv="python opa2vec/runWord2Vec.py "+str(finalclasses.name)+" "+str(window)+" "+str(embedding)+" "+str(mincoun)+" "+str(model)+" opa2vec/"+str(pretrained)+" "+ str(ontology_corpus.name)+" "+ str(tempvecs.name)
print(f"Команда запсука: {cmdwv}")
os.system(cmdwv)

print("		*********** Vector representations created ***********\n")

#6. Process vectors
cmdproc="python opa2vec/process_vectors.py " + str(tempvecs.name)+" > "+ str(outfile)
os.system (cmdproc)
#7. Finalize and clean-up
print("\n		*********** OPA2Vec Complete ***********\n")

axiomsinf.close()
axiomsorig.close()
classesfile.close()
axioms.close()
metadatafile.close()
annotated_meta.close()
annot_classes.close()
finalclasses.close()
AssoAxiomInferred.close()
Assoc1.close()
Assoc2.close()
ontology_corpus.close()
tempvecs.close()







