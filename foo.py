a = ""

def foo(s):
    global a
    a += s

foo("Hello, ")
foo("World!")

print(a)
