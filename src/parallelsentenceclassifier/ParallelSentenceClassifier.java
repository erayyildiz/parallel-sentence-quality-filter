/*
 * To change this template, choose Tools | Templates
 * and open the template in the editor.
 */
package parallelsentenceclassifier;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.LineNumberReader;
import java.io.OutputStreamWriter;
import java.io.UnsupportedEncodingException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import weka.classifiers.trees.RandomForest;
import weka.core.DenseInstance;
import weka.core.Instance;
import weka.core.Instances;
import weka.core.converters.ArffLoader;



/**
 *
 * @author Eray
 */
public class ParallelSentenceClassifier {

    /**
     * @param args the command line arguments
     */
    public static Map<String,String> Dictionary;
    public static double wrong_words_count;
    public static double ngram_score;
    public static double translation_score;
    public static double length_ratio;
    public static double length_en;
    public static double length_differ;
    public static void main(String[] args) throws UnsupportedEncodingException, FileNotFoundException, IOException, Exception {
        //args: dictionary_file english_file turkish_file -train > print arff
        //args: dictionary_file english_file turkish_file -test arff_file (printing filtered instances)
        InputStreamReader inputStreamReader = new InputStreamReader(new FileInputStream(new File(args[1])), "UTF-8");
        InputStreamReader inputStreamReader2 = new InputStreamReader(new FileInputStream(new File(args[2])), "UTF-8");
        BufferedReader oku = new BufferedReader (inputStreamReader);
        BufferedReader oku2 = new BufferedReader (inputStreamReader2);
        BufferedWriter out1 = new BufferedWriter(new OutputStreamWriter(new FileOutputStream(args[1]+"_Filtered.txt"),"UTF-8"));
        BufferedWriter out2 = new BufferedWriter(new OutputStreamWriter(new FileOutputStream(args[2]+"_Filtered.txt"),"UTF-8"));
        BufferedWriter out3 = new BufferedWriter(new OutputStreamWriter(new FileOutputStream(args[2]+"_Eleminated.txt"),"UTF-8"));
        ArffLoader loader;
        RandomForest classifier = null;
        //WLSVM classifier2 = null;
        Instances data = null ;
        ArrayList<Double> vector;
        switch (args[3]) {
            case "-train":
            {
                
                System.out.println("@relation parallel_sentence_quality");
                System.out.println("@attribute wrong_words_count numeric");
                System.out.println("@attribute ngram_score numeric");
                System.out.println("@attribute sentence_length_en numeric");
                System.out.println("@attribute translation_score numeric");
                System.out.println("@attribute length_differ numeric");
                System.out.println("@attribute length_ratio numeric");
                System.out.println("@attribute class {'kaliteli', 'kalitesiz'}");
                System.out.println("@data");
                break;
            }
            case "-test":
            {
                System.out.println("Sınıflandırıcı ayarlanıyor...");
                 loader = new ArffLoader();
                 loader.setFile(new File(args[4]));
                 classifier = new RandomForest();
//                 classifier2 = new WLSVM();
//                 String[] ops = {"-S", "0", "-K", "2", "-D", "3", "-G", "0", "-R", "0", "-N", "0.5", "-E", "0.001", "-P", "0.1", "-C", "100", "-Z", "1", "-M", "40", "-H", "-Z", "-W", "1.0 1.0", "-seed", "1"};
//                 classifier2.setOptions(ops);
                 data = loader.getDataSet();
                 data.setClassIndex(6);
                 classifier.buildClassifier(data);
                 //classifier2.buildClassifier(data);
                 System.out.println("Verilen dosyalardaki örnekler sınıflandırılıyor...");
                break;
            }
            default:
            {
              System.err.print("Söz dizimi hatası");
             System.out.print("Söz dizimi hatası");
             System.exit(1);
             break;
            }
                
        }
         int i = 1;
        LineNumberReader  lnr = new LineNumberReader(new FileReader(new File(args[1])));
        lnr.skip(Long.MAX_VALUE);
        
         while(oku.ready()&&oku2.ready()){
                    
                    String en_sentence=initialize(oku.readLine());
                    String tr_sentence=initialize(oku2.readLine());
//                      String en_sentence=initialize("i think");
//                      String tr_sentence=initialize("Buna da alışırım zamanla.");
                    if(initialFilter(en_sentence, tr_sentence))
                    {
                        vector= new ArrayList<>();
                        JazzySpellChecker jazzySpellChecker = new JazzySpellChecker();
                        //Spell Checker
                        String en_sentenceforchecker=en_sentence.replaceAll("[\\d\\.,;:\\?!\\(\\)\\[\\]\\-]*", "");
                        en_sentenceforchecker = en_sentenceforchecker.replaceAll(" [A-ZÜİŞÇÖ]+[^ ]*", " ");
                        en_sentenceforchecker = en_sentenceforchecker.replaceAll("([\\(\\[])[A-ZÜİŞÇÖ]+[^ ]*", "$1 ");
                        en_sentenceforchecker=en_sentenceforchecker.replaceAll("\t+", " ");
                        en_sentenceforchecker=en_sentenceforchecker.replaceAll(" +", " ");
                        List<String> misSpelledWords = jazzySpellChecker.getMisspelledWords(en_sentenceforchecker);
                        wrong_words_count=misSpelledWords.size();
                        //eşleşme skor
                        ContentFilter cf = new ContentFilter(args[0], en_sentence, tr_sentence);
                        translation_score=cf.get_ratio();
                        //uzunluk farkı ve oranı
                        length_ratio=(double)((double)WordCount(en_sentence)/(double)WordCount(tr_sentence));
                        length_differ=Math.abs(WordCount(en_sentence)-WordCount(tr_sentence));
                        length_en=WordCount(en_sentence);

                        //ngram skor
                        NgramScore ns = new NgramScore(en_sentence);
                        //ngram_score=Math.pow((double)Math.abs(ns.score), (double)((double)1/(double)WordCount(en_sentence)));
                        ngram_score=ns.score;
                        //diğer özellikler
                        //vektörü oluştur 
                        vector.add(wrong_words_count); vector.add(ngram_score); vector.add(length_en); vector.add(translation_score); vector.add(length_differ); vector.add(length_ratio);
                 //train ve test parametresi al args[3]
                 switch (args[3]) {
                     case "-train":
                     {
                         for(Double d : vector)
                         {
                             String result = String.format("%.2f", d);
                             System.out.print(result.replaceAll(",", "."));
                             System.out.print(",");
                             
                         }
                         System.out.println("'kalitesiz'");
                         //kalitesiz ve kaliteliyi örneklere göre değiştirin
                         break;
                     }
                     case "-test":
                     {
                         
                         
                          
                         Instance instance = new DenseInstance(6);
                         for(int j = 0; j<6; j++)
                         {
                             instance.insertAttributeAt(j);
                             instance.setValue(j, vector.get(j));
                         }
                         
                         
                         instance.setDataset(data);
                         //Double clas = classifier.classifyInstance(instance);
                         double clas[] = classifier.distributionForInstance(instance);
                         //Double clas2 = classifier2.classifyInstance(instance);
//                         System.out.println(en_sentence+" <=> "+tr_sentence);
                         
                         System.out.print(Integer.toString(i)+"/"+Integer.toString(lnr.getLineNumber())+"\r");
                         if(clas[0]==1)
                         {
                            out1.write(en_sentence+"\r\n"); 
                            out2.write(tr_sentence+"\r\n");
                         }
                         else
                         {
                             out3.write(en_sentence+"\r\n"+tr_sentence+"\r\n\r\n");
                         }
                         out1.flush();out2.flush();out3.flush();
                         break;
                     }
                     default:
                     {
                         System.err.print("Söz dizimi hatası");
                         System.out.print("Söz dizimi hatası");
                         System.exit(1);
                         break;
                         
                     }
                 }
               }
                    out1.flush();
                    out2.flush();
                    out3.flush();
                    
               i++;
         }
         out1.close();
         out2.close();
         out3.close();
    }
    public static int WordCount(String sentence)
    {
        int count = sentence.trim().split(" ").length+1;
        return count;
    }
    public static String initialize(String sentence)
    {
       if(sentence.matches("^[^\\\"]*\\\"[^\\\"]*"))
        {
            sentence=sentence.replaceAll("\\\"", "");
        }
        
        
        sentence=sentence.replaceAll("([a-zA-ZÜĞİŞÇüğışçöÖ])' *([a-zA-ZÜĞİŞÇüğışçöÖ])","$1'$2");
        // remove extra spaces
        sentence=sentence.replaceAll("\\("," \\(");
        sentence=sentence.replaceAll("\\)","\\) "); 
        sentence=sentence.replaceAll(" +"," ");
        sentence=sentence.replaceAll("\\) ([\\.\\!\\:\\?\\;\\,])","\\)$1");
        sentence=sentence.replaceAll("\\( ","\\(");
        sentence=sentence.replaceAll(" \\)","\\)");
        sentence=sentence.replaceAll("(\\d) \\%","$1\\%");
        sentence=sentence.replaceAll("\\% (\\d)","\\%$1");

        // normalize unicode punctuation
        sentence=sentence.replaceAll("„","\\\"");
        sentence=sentence.replaceAll("“","\\\"");
        sentence=sentence.replaceAll("”","\\\"");
        sentence=sentence.replaceAll("–","-");
        sentence=sentence.replaceAll("—"," - "); 
        sentence=sentence.replaceAll(" +"," ");
        sentence=sentence.replaceAll("´","\\'");
        sentence=sentence.replaceAll("([a-zA-ZÜĞİŞÇüğışçöÖ])‘([a-zA-ZÜĞİŞÇüğışçöÖ])","$1\\'$2");
        sentence=sentence.replaceAll("([a-zA-ZÜĞİŞÇüğışçöÖ])’([a-zA-ZÜĞİŞÇüğışçöÖ])","$1\\'$2");
        sentence=sentence.replaceAll("‘","");
        sentence=sentence.replaceAll("‚","");
        sentence=sentence.replaceAll("’","");
        sentence=sentence.replaceAll("''","\\\"");
        sentence=sentence.replaceAll("´´","\\\"");
        sentence=sentence.replaceAll("…","...");
        // French quotes
        sentence=sentence.replaceAll(" « "," \\\"");
        sentence=sentence.replaceAll("« ","\\\"");
        sentence=sentence.replaceAll("«","\\\"");
        sentence=sentence.replaceAll(" » ","\\\" ");
        sentence=sentence.replaceAll(" »","\\\"");
        sentence=sentence.replaceAll("»","\\\"");
        // handle pseudo-spaces
        sentence=sentence.replaceAll("nº ","");
        sentence=sentence.replaceAll(" :",":");
        sentence=sentence.replaceAll(" \\?","\\?");
        sentence=sentence.replaceAll(" \\!","\\!");
        sentence=sentence.replaceAll(" ;",";");
        sentence=sentence.replaceAll(" \\.",".");
        sentence=sentence.replaceAll(" :",":");
        sentence=sentence.replaceAll(" ,",",");
        sentence=sentence.replaceAll(", ",", "); 
        
       
        
        //for subtitles
        sentence=sentence.replaceAll(" \\[ Getty Images \\]$", "");
        sentence=sentence.replaceAll("\\.([A-ZÜĞİŞÇÖ])",". $1");
        sentence=sentence.replaceAll(";([A-Za-züğışçöÜĞİŞÇÖ])","; $1");
        sentence=sentence.replaceAll(",([A-Za-züğışçöÜĞİŞÇÖ])",", $1");
        sentence=sentence.replaceAll("\\?([A-Za-züğışçöÜĞİŞÇÖ])","? $1");
        sentence=sentence.replaceAll("\\!([A-Za-züğışçöÜĞİŞÇÖ])","! $1");
        sentence=sentence.replaceAll("\\.\\.+ *\\.\\.+"," ");
        sentence=sentence.replaceAll("^ *-", "");
        sentence=sentence.replaceAll("\\. *[\\[\\(\\{]?\\d*[\\)\\]\\}]?$", ".");
        
        
         //spaces
        sentence=sentence.replaceAll("^ *\t* *", "");
        sentence=sentence.trim();
        sentence=sentence.replaceAll(" +"," ");
       
        return sentence;
    }
    public static boolean initialFilter(String sentence1, String sentence2)
    {
        if((sentence1.matches("^.*[©~½$#=&Ä±Ã§Â»].*$"))||(sentence2.matches("^.*[©~½$#=&Ä±Ã§Â»].*$")))
        {
            return false;
        }
        else if((sentence1.length()<40)||(sentence2.length()<40))
        {
            return false;
        }
        return true;
    }
    
}
