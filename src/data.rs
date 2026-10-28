use std::io::Read;
use serde_json::Value;
use serde::{Serialize, Deserialize};


#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct YaraPrompt {
    pub prompt: serde_json::Map<String, Value>,
    pub workflow: Value,
    pub hash: String,
    pub ip_port: String,
}
impl YaraPrompt {
    pub fn new(nodemap: serde_json::Map<String, Value>, workflow: Value, ip_port: &str) -> YaraPrompt {
        let hash = hash_nodemap(&nodemap);
        let mut prompt = serde_json::Map::new();
        prompt.insert("prompt".to_string(), Value::Object(nodemap));
        YaraPrompt {
            prompt,
            workflow,
            hash,
            ip_port: ip_port.to_string(),
        }
    }
    pub fn generate(&self) -> Result<String, String> {
        let prompt_string = serde_json::to_string(&self.prompt).unwrap();

        let mut response = match isahc::post(self.ip_port.clone() + "prompt", prompt_string) {
            Ok(response) => response,
            Err(err) => {
                return Err(format!(
                    "could not reach ComfyUI at {ip_port}: {err}. Is ComfyUI running, and are the comfyui_address/comfyui_port settings correct?",
                    ip_port = self.ip_port
                ));
            }
        };

        let mut buf = String::new();
        response
            .body_mut()
            .read_to_string(&mut buf)
            .map_err(|err| format!("could not read response from ComfyUI: {err}"))?;

        if !(response.status().is_informational() || response.status().is_success()) {
            let detail = serde_json::from_str::<Value>(&buf)
                .map(|v| v.to_string())
                .unwrap_or(buf.clone());
            return Err(format!(
                "ComfyUI rejected the prompt (status {}): {}",
                response.status(),
                detail
            ));
        }

        let json: Value = serde_json::from_str(&buf)
            .map_err(|err| format!("could not parse response from ComfyUI: {err}\nRaw response: {buf}"))?;
        let id = json
            .as_object()
            .ok_or_else(|| format!("unexpected response from ComfyUI: {buf}"))?
            .get("prompt_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| format!("no prompt_id in response from ComfyUI: {buf}"))?;
        println!("// Generating prompt // {id}");
        Ok(id.to_string())
    }
}

/// Fetch a JSON endpoint from ComfyUI.
///
/// Some custom nodes can produce NaN/Infinity values in API data, which strict
/// JSON parsers reject; in that case a lenient parser is used as a fallback
/// (such values become null). If ComfyUI can't be reached or the response can't
/// be parsed, a friendly error is printed and the program exits.
pub fn fetch_json(url: &str) -> Value {
    let mut response = match isahc::get(url) {
        Ok(response) => response,
        Err(err) => {
            eprintln!("\x1b[31merror\x1b[0m:// could not connect to ComfyUI at {url}: {err}");
            eprintln!("Is ComfyUI running, and are the comfyui_address/comfyui_port settings correct?");
            std::process::exit(1);
        }
    };
    let mut buf = String::new();
    if let Err(err) = response.body_mut().read_to_string(&mut buf) {
        eprintln!("\x1b[31merror\x1b[0m:// could not read response from {url}: {err}");
        std::process::exit(1);
    }
    match serde_json::from_str::<Value>(&buf) {
        Ok(value) => value,
        Err(_) => match json5::from_str::<Value>(&buf) {
            Ok(value) => {
                eprintln!("\x1b[33mwarning\x1b[0m:// {url} contained non-strict JSON (e.g. NaN from a custom node); invalid values were converted to null.");
                value
            }
            Err(err) => {
                eprintln!("\x1b[31merror\x1b[0m:// could not parse response from {url}: {err}");
                eprintln!("Raw response: {buf}");
                std::process::exit(1);
            }
        },
    }
}





#[derive(Debug)]
struct Node {
    id: u64,
    contents: Value,
}

fn get_field(mut bytes: &mut Vec<u8>, input: &Value) {
    if let Some(field) = input.as_f64() {
        bytes.extend(field.to_be_bytes());
    } else if let Some(field) = input.as_str() {
        bytes.extend(field.bytes());
    } else if let Some(array) = input.as_array() {
        get_field(&mut bytes, &array[0]);
        get_field(&mut bytes, &array[1]);
    } else {
        println!("Warning - while hashing nodes, unexpected input");
        bytes.extend(input.to_string().bytes());
    }
}

impl Node {
    // We define a function to turn it into bytes.
    // Note that we can't just hash it directly, because it seems ComfyUI randomly
    // changes parts of the prompt (e.g. node ordering, or turning a float into an integer)
    fn to_bytes(&self) -> Vec<u8> {
        let mut bytes: Vec<u8> = Vec::from(self.id.to_be_bytes());

        let class_type = self.contents.get("class_type").unwrap().as_str().unwrap();
        bytes.extend(class_type.as_bytes());

        let inputs = self.contents.get("inputs").unwrap().as_object().unwrap();
        let mut keys: Vec<String> = inputs.keys().map(|x| x.to_string()).collect(); // sort this alphabetically
        keys.sort();
        for key in keys {
            let input = inputs.get(&key).unwrap();
            get_field(&mut bytes, input);
        }

        bytes
    }
}

pub fn hash_nodemap(nodemap: &serde_json::Map<String, Value>) -> String {

    let mut nodes: Vec<Node> = Vec::new();
    for id in nodemap.keys() {
        nodes.push(Node {
            id: id.parse::<u64>().unwrap(),
            contents: nodemap.get(id).unwrap().clone(),
        });
    }
    nodes.sort_by(|a, b| a.id.partial_cmp(&b.id).unwrap()); 

    let mut hasher = blake3::Hasher::new();
    for node in nodes {
        hasher.update(&node.to_bytes());
    }
    hasher.finalize().to_hex().as_str().to_string()
}