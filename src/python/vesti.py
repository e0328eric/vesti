def sprint(str):
    global __vesti_output_str__
    __vesti_output_str__ += str

def sprintn(str):
    global __vesti_output_str__
    __vesti_output_str__ += f"{str}\n"

def sprintln(str):
    global __vesti_output_str__
    __vesti_output_str__ += f"{str}\n\n"
