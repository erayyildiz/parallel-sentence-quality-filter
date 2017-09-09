/*
 * To change this template, choose Tools | Templates
 * and open the template in the editor.
 */
package parallelsentenceclassifier;


import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.UnsupportedEncodingException;
import java.util.HashMap;
import java.util.Map;





/**
 *
 * @author Eray
 */
public class ContentFilter {
    public static Map<String,String> Dictionary;
    public String en_sentence;
    public String tr_sentence;
    public double ratio;
    public ContentFilter(String dict_file, String str1, String str2) throws UnsupportedEncodingException, FileNotFoundException, IOException
    {
        Dictionary=loadDict(dict_file);
        this.en_sentence=str1;
        this.en_sentence=this.en_sentence.replaceAll("\\.", "");
        this.en_sentence=this.en_sentence.replaceAll(",", "");        
        this.en_sentence=this.en_sentence.replaceAll(";", "");
        this.en_sentence=this.en_sentence.replaceAll("\\?", "");
        this.en_sentence=this.en_sentence.replaceAll("!", "");
        this.en_sentence=this.en_sentence.replaceAll("\\!", "");
        this.en_sentence=this.en_sentence.replaceAll(":", "");
        this.en_sentence=this.en_sentence.replaceAll("\\\"", "");
        
        this.tr_sentence=str2;
        this.tr_sentence=this.tr_sentence.replaceAll("\\.", "");
        this.tr_sentence=this.tr_sentence.replaceAll(",", "");        
        this.tr_sentence=this.tr_sentence.replaceAll(";", "");
        this.tr_sentence=this.tr_sentence.replaceAll("\\?", "");
        this.tr_sentence=this.tr_sentence.replaceAll("!", "");
        this.en_sentence=this.en_sentence.replaceAll("\\!", "");
        this.tr_sentence=this.tr_sentence.replaceAll(":", "");
        this.en_sentence=this.en_sentence.replaceAll("\\\"", "");
        
        int total_count=0;
        int translate_count = 0;
        String extended ="";
        for(String en_word : en_sentence.split(" "))
        {
            
            if((en_word.matches(".*[0-9]+.*"))||(en_word.matches("^[A-Z].*"))) {
                extended=extended+" "+en_word.toLowerCase();
            }
            try{
                String entry=Dictionary.get(en_word.toLowerCase()).toLowerCase();
                extended=extended+" "+entry;
               
                
            }
            catch(Exception e)
            {
                    
            }
            
        }

        for(String tr_word : tr_sentence.split(" "))
        {
            total_count++;
            String tr_word2=tr_word.toLowerCase();
            if(tr_word2.length()>5){
                   tr_word2=tr_word2.substring(0,5);
                }
            if((extended.contains(tr_word2+" "))||(extended.contains(" "+tr_word2)))
            {
                translate_count++;
            }
        }
        //System.out.println(en_sentence+"  ------------------ "+tr_sentence+" ----------------- "+extended);
        this.ratio=(double)translate_count/(double)total_count;
    }
    public double get_ratio()
    {
        
        return this.ratio;
    }
    public static Map<String,String> loadDict(String dictFileName) throws UnsupportedEncodingException, FileNotFoundException, IOException{
        Map<String,String> dictMap = new HashMap<>();
        InputStreamReader inputStreamReader = new InputStreamReader(new FileInputStream(new File(dictFileName)), "UTF-8");
        try (BufferedReader oku = new BufferedReader (inputStreamReader)) {

            while(oku.ready()){
                String record = oku.readLine();
                String[] pairs = record.split(" <> ",2);
                String en_word = pairs[0];
                String tr_word=pairs[1];
                if(dictMap.containsKey(en_word))
                {
                    
                    dictMap.put(en_word,dictMap.get(en_word).replaceAll("(.+)", "$1 "+tr_word));
                }
                else
                {
                    dictMap.put(en_word, tr_word);
                }
                
            }
        }
      
        return dictMap;
        
    }
   
}


