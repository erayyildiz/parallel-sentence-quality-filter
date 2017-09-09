/*
 * To change this template, choose Tools | Templates
 * and open the template in the editor.
 */
package parallelsentenceclassifier;

/**
 *
 * @author Eray
 */
 
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
 
 
 
import com.swabunga.spell.engine.SpellDictionaryHashMap;
import com.swabunga.spell.engine.Word;
import com.swabunga.spell.event.SpellCheckEvent;
import com.swabunga.spell.event.SpellCheckListener;
import com.swabunga.spell.event.SpellChecker;
import com.swabunga.spell.event.StringWordTokenizer;
import com.swabunga.spell.event.TeXWordFinder;
 
public class JazzySpellChecker implements SpellCheckListener {
  
 private SpellChecker spellChecker;
 private List<String> misspelledWords;
  
 /**
  * get a list of misspelled words from the text
  * @param text
  */
 public List<String> getMisspelledWords(String text) {
  StringWordTokenizer texTok = new StringWordTokenizer(text,
    new TeXWordFinder());
  spellChecker.checkSpelling(texTok);
  return misspelledWords;
 }
  
 private static SpellDictionaryHashMap dictionaryHashMap;
  
 static{
  
  File dict = new File("C:\\Users\\Eray\\Documents\\NetBeansProjects\\ParallelSentenceClassifier\\words.utf-8.txt");
  try {
   dictionaryHashMap = new SpellDictionaryHashMap(dict);
  } catch (FileNotFoundException e) {
  } catch (IOException e) {
  }
 }
  
 private void initialize(){
   spellChecker = new SpellChecker(dictionaryHashMap);
   spellChecker.addSpellCheckListener(this);  
 }
  
  
 public JazzySpellChecker() {
   
  misspelledWords = new ArrayList<>();
  initialize();
 }
 @Override
 public void spellingError(SpellCheckEvent event) {
  event.ignoreWord(true);
  misspelledWords.add(event.getInvalidWord());
 }

}